#!/usr/bin/env python3
"""Inspect PICO data read through runService and its VRDataMessage mapping."""
import argparse
import json
import os
import sys
import time
from pathlib import Path

import numpy as np

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT))


def ensure_localhost_bypasses_proxy():
    localhost_hosts = ("127.0.0.1", "localhost")
    for key in ("NO_PROXY", "no_proxy"):
        existing = os.environ.get(key, "")
        values = [item.strip() for item in existing.split(",") if item.strip()]
        for host in localhost_hosts:
            if host not in values:
                values.append(host)
        os.environ[key] = ",".join(values)


def as_list(value):
    return list(np.array(value).flatten())


def collect_raw_frame(xrt):
    return {
        "timestamp_ns": xrt.get_time_stamp_ns(),
        "headset_pose": as_list(xrt.get_headset_pose()),
        "left_controller": {
            "pose": as_list(xrt.get_left_controller_pose()),
            "trigger": float(xrt.get_left_trigger()),
            "grip": float(xrt.get_left_grip()),
            "axis": as_list(xrt.get_left_axis()),
            "axis_click": bool(xrt.get_left_axis_click()),
            "menu_button": bool(xrt.get_left_menu_button()),
        },
        "right_controller": {
            "pose": as_list(xrt.get_right_controller_pose()),
            "trigger": float(xrt.get_right_trigger()),
            "grip": float(xrt.get_right_grip()),
            "axis": as_list(xrt.get_right_axis()),
            "axis_click": bool(xrt.get_right_axis_click()),
            "menu_button": bool(xrt.get_right_menu_button()),
        },
        "buttons": {
            "A": bool(xrt.get_A_button()),
            "B": bool(xrt.get_B_button()),
            "X": bool(xrt.get_X_button()),
            "Y": bool(xrt.get_Y_button()),
        },
    }


def main():
    parser = argparse.ArgumentParser(description="Inspect PICO -> xrobotoolkit_sdk -> VRDataMessage")
    parser.add_argument("--count", type=int, default=100, help="Number of frames to print")
    parser.add_argument("--interval", type=float, default=0.5, help="Seconds between frames")
    args = parser.parse_args()

    ensure_localhost_bypasses_proxy()

    try:
        import xrobotoolkit_sdk as xrt
    except ImportError as e:
        print(f"Failed to import xrobotoolkit_sdk: {e}", file=sys.stderr)
        return 1

    print(f"[runtime] python: {sys.executable}")
    print(f"[runtime] xrobotoolkit_sdk: {getattr(xrt, '__file__', xrt)}")
    print(f"[runtime] NO_PROXY: {os.environ.get('NO_PROXY', '')}")
    print(f"[runtime] no_proxy: {os.environ.get('no_proxy', '')}")

    from robo_avatar.vr_teleop.vr_data_publisher import VRDataPublisher

    try:
        xrt.init()
    except Exception as e:
        print(f"Failed to initialize xrobotoolkit_sdk. Is runService running? {e}", file=sys.stderr)
        return 1

    publisher = VRDataPublisher({})
    try:
        for index in range(args.count):
            raw_frame = collect_raw_frame(xrt)
            message = publisher._collect_vr_data()

            print("=" * 80)
            print(f"Frame {index + 1}/{args.count}")
            print("\n[1] Raw data from xrobotoolkit_sdk")
            print(json.dumps(raw_frame, ensure_ascii=False, indent=2))
            print("\n[2] VRDataMessage produced by vr_data_publisher")
            if message is None:
                print("None")
            else:
                print(json.dumps(message.to_dict(), ensure_ascii=False, indent=2))
                print("\n[3] JSON sent over ZeroMQ by publisher")
                print(message.to_json())

            if index + 1 < args.count:
                time.sleep(args.interval)
    finally:
        try:
            xrt.close()
        except Exception:
            pass

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
