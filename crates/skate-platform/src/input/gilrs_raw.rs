//! Non-Windows device transport via gilrs with its default filters disabled,
//! so evdev values reach the TU3 converter without deadzones.
//!
//! Range normalization: gilrs exposes stick axes as f32 in -1..1 and analog
//! triggers as 0..1, while the shared converter expects XInput ranges
//! (i16 sticks, u8 triggers). Sticks are scaled by 32767 and triggers by 255.
use super::*;
use gilrs::{Axis, Button, Gilrs};
use std::cell::{Cell, RefCell};

// Community controller DB (SDL_GameControllerDB): generic HID pads do not
// self-describe their layout, so mappings come from this VID/PID-keyed list,
// the same one used by SDL/Steam/gilrs upstream. Users can override or extend
// it with the standard SDL_GAMECONTROLLERCONFIG env var.
const GAMECONTROLLERDB: &str = include_str!("../../gamecontrollerdb.txt");

// Extra GUID rows. DragonRise reports version 1001 (upstream has 0107).
// Steam Deck (28de:1205) firmware versions the bundled DB may omit.
const EXTRA_MAPPINGS: &str = "\
03000000790000000600000010010000,DragonRise Inc. Generic USB Joystick,platform:Linux,a:b2,b:b1,x:b3,y:b0,back:b8,start:b9,leftstick:b10,rightstick:b11,leftshoulder:b4,rightshoulder:b5,dpup:h0.1,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,leftx:a0,lefty:a1,rightx:a2,righty:a3,lefttrigger:b6,righttrigger:b7,\n\
03000000de2800000512000000000000,Valve Steam Deck,a:b3,b:b4,back:b11,dpdown:b17,dpleft:b18,dpright:b19,dpup:b16,guide:b13,leftshoulder:b7,leftstick:b14,lefttrigger:a9,leftx:a0,lefty:a1,rightshoulder:b8,rightstick:b15,righttrigger:a8,rightx:a2,righty:a3,start:b12,x:b5,y:b6,platform:Linux,\n\
03000000de2800000512000001000000,Valve Steam Deck,a:b3,b:b4,back:b11,dpdown:b17,dpleft:b18,dpright:b19,dpup:b16,guide:b13,leftshoulder:b7,leftstick:b14,lefttrigger:a9,leftx:a0,lefty:a1,rightshoulder:b8,rightstick:b15,righttrigger:a8,rightx:a2,righty:a3,start:b12,x:b5,y:b6,platform:Linux,\n\
05000000de2800000512000001000000,Valve Steam Deck,a:b3,b:b4,back:b11,dpdown:b17,dpleft:b18,dpright:b19,dpup:b16,guide:b13,leftshoulder:b7,leftstick:b14,lefttrigger:a9,leftx:a0,lefty:a1,rightshoulder:b8,rightstick:b15,righttrigger:a8,rightx:a2,righty:a3,start:b12,x:b5,y:b6,platform:Linux,\n\
";

thread_local! {
    static GILRS: RefCell<Option<Gilrs>> = const { RefCell::new(None) };
    static PACKET: Cell<u32> = const { Cell::new(0) };
    static LOGGED: RefCell<String> = const { RefCell::new(String::new()) };
}

/// Rank evdev nodes so a Steam Deck touchpad/keyboard does not steal slot 0.
pub(crate) fn pad_score(name: &str, mapped: bool, has_left_stick: bool) -> i32 {
    let n = name.to_ascii_lowercase();
    if ["keyboard", "mouse", "touchpad", "trackpad", "touch screen"]
        .iter()
        .any(|needle| n.contains(needle))
    {
        return -10;
    }
    let mut score = 0;
    if mapped {
        score += 4;
    }
    if has_left_stick {
        score += 2;
    }
    if [
        "steam deck",
        "neptune",
        "x-box",
        "xbox",
        "xinput",
        "steam virtual",
    ]
    .iter()
    .any(|needle| n.contains(needle))
    {
        score += 3;
    }
    score
}

fn with_gilrs<R>(f: impl FnOnce(&mut Gilrs) -> R) -> Result<R, DeviceError> {
    GILRS.with(|cell| {
        let mut slot = cell.borrow_mut();
        if slot.is_none() {
            let gilrs = gilrs::GilrsBuilder::new()
                .with_default_filters(false)
                .add_env_mappings(true)
                .add_mappings(GAMECONTROLLERDB)
                .add_mappings(EXTRA_MAPPINGS)
                .build()
                .map_err(|_| DeviceError::State(1))?;
            *slot = Some(gilrs);
        }
        Ok(f(slot.as_mut().unwrap()))
    })
}

fn select_pads(gilrs: &Gilrs) -> Vec<gilrs::GamepadId> {
    let mut pads: Vec<(i32, gilrs::GamepadId, String)> = gilrs
        .gamepads()
        .filter(|(_, gamepad)| gamepad.is_connected())
        .map(|(id, gamepad)| {
            let has_stick = gamepad.axis_data(Axis::LeftStickX).is_some()
                && gamepad.axis_data(Axis::LeftStickY).is_some();
            let score = pad_score(gamepad.name(), gamepad.is_mapped(), has_stick);
            (
                score,
                id,
                format!(
                    "{} mapped={} stick={} score={score}",
                    gamepad.name(),
                    gamepad.is_mapped(),
                    has_stick
                ),
            )
        })
        .collect();
    if pads.iter().any(|(score, _, _)| *score > 0) {
        pads.retain(|(score, _, _)| *score > 0);
    }
    pads.sort_by(|a, b| b.0.cmp(&a.0).then(usize::from(a.1).cmp(&usize::from(b.1))));
    let summary = pads
        .iter()
        .map(|(_, _, line)| line.as_str())
        .collect::<Vec<_>>()
        .join(" | ");
    LOGGED.with(|logged| {
        let mut logged = logged.borrow_mut();
        if *logged != summary {
            if summary.is_empty() {
                eprintln!("INPUT no gamepad (Steam Deck: hold ☰ Start 2s to leave desktop keyboard mode)");
            } else {
                eprintln!("INPUT {summary}");
            }
            *logged = summary;
        }
    });
    pads.into_iter().map(|(_, id, _)| id).collect()
}

fn button_bits(gamepad: &gilrs::Gamepad) -> u16 {
    // XInput XUSB button bitmask, matching the Windows transport.
    let pressed = |button: Button| gamepad.is_pressed(button);
    let mut bits = 0u16;
    for (button, bit) in [
        (Button::DPadUp, 0x0001),
        (Button::DPadDown, 0x0002),
        (Button::DPadLeft, 0x0004),
        (Button::DPadRight, 0x0008),
        (Button::Start, 0x0010),
        (Button::Select, 0x0020),
        (Button::LeftThumb, 0x0040),
        (Button::RightThumb, 0x0080),
        (Button::LeftTrigger, 0x0100),
        (Button::RightTrigger, 0x0200),
        (Button::Mode, 0x0400),
        (Button::South, 0x1000),
        (Button::East, 0x2000),
        (Button::West, 0x4000),
        (Button::North, 0x8000),
    ] {
        if pressed(button) {
            bits |= bit;
        }
    }
    bits
}

fn axis(gamepad: &gilrs::Gamepad, axis: Axis) -> i16 {
    let value = gamepad.axis_data(axis).map_or(0.0, |data| data.value());
    (value.clamp(-1.0, 1.0) * 32767.0).round() as i16
}

fn trigger(gamepad: &gilrs::Gamepad, button: Button, axis: Axis) -> u8 {
    if let Some(data) = gamepad.button_data(button) {
        return (data.value().clamp(0.0, 1.0) * 255.0).round() as u8;
    }
    // Fallback for pads reporting triggers as axes normalized to -1..1.
    let value = gamepad.axis_data(axis).map_or(-1.0, |data| data.value());
    ((value.clamp(-1.0, 1.0) + 1.0) * 0.5 * 255.0).round() as u8
}

pub(super) fn poll(index: u32, cache: &mut CapabilityCache) -> Result<DevicePacket, DeviceError> {
    with_gilrs(|gilrs| {
        while let Some(_event) = gilrs.next_event() {}
        let connected = select_pads(gilrs);
        let Some(&id) = connected.get(index as usize) else {
            cache.invalidate();
            return Err(DeviceError::Disconnected);
        };
        let subtype = cache.get(std::time::Instant::now(), || Ok(1))?;
        let gamepad = gilrs.gamepad(id);
        let number = PACKET.with(|packet| {
            let number = packet.get().wrapping_add(1);
            packet.set(number);
            number
        });
        Ok(DevicePacket {
            number,
            state: XboxState {
                buttons: button_bits(&gamepad),
                triggers: [
                    trigger(&gamepad, Button::LeftTrigger2, Axis::LeftZ),
                    trigger(&gamepad, Button::RightTrigger2, Axis::RightZ),
                ],
                left: [axis(&gamepad, Axis::LeftStickX), axis(&gamepad, Axis::LeftStickY)],
                right: [axis(&gamepad, Axis::RightStickX), axis(&gamepad, Axis::RightStickY)],
            },
            subtype,
        })
    })?
}

#[cfg(test)]
mod tests {
    use super::pad_score;

    #[test]
    fn steam_deck_outranks_touchpad_and_keyboard() {
        let deck = pad_score("Valve Steam Deck", true, true);
        assert!(deck > pad_score("Steam Deck Touchpad", true, false));
        assert!(deck > pad_score("Valve Software Steam Keyboard", false, false));
        assert!(deck > pad_score("Generic USB Joystick", false, false));
    }

    #[test]
    fn xbox_alias_is_preferred_over_unmapped() {
        assert!(pad_score("Microsoft X-Box 360 pad", true, true) > pad_score("Unknown", false, false));
    }
}
