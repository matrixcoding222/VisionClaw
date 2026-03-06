#!/usr/bin/env python3
"""
Calibration Overlay - Displays 4 QR codes at screen corners.

The iOS app detects these QR codes to establish a mapping between the
camera's field of view and the Mac screen coordinates.

Usage:
  pip install qrcode Pillow
  python calibration_overlay.py

Press Escape or Q to quit.
"""

import sys
import tkinter as tk
from io import BytesIO

try:
    import qrcode
    from PIL import Image, ImageTk
except ImportError:
    print("Missing dependencies. Install with:")
    print("  pip install qrcode Pillow")
    sys.exit(1)


MARKER_SIZE = 120
MARGIN = 40

MARKERS = {
    "TL": "nw",  # top-left
    "TR": "ne",  # top-right
    "BL": "sw",  # bottom-left
    "BR": "se",  # bottom-right
}


def generate_qr(data, size):
    qr = qrcode.QRCode(
        version=1,
        error_correction=qrcode.constants.ERROR_CORRECT_H,
        box_size=10,
        border=2,
    )
    qr.add_data(data)
    qr.make(fit=True)
    img = qr.make_image(fill_color="black", back_color="white")
    img = img.resize((size, size), Image.NEAREST)
    return img


class CalibrationOverlay:
    def __init__(self):
        self.root = tk.Tk()
        self.root.title("Gaze Calibration")
        self.root.attributes("-topmost", True)

        screen_w = self.root.winfo_screenwidth()
        screen_h = self.root.winfo_screenheight()

        self.root.geometry(f"{screen_w}x{screen_h}+0+0")
        self.root.configure(bg="black")
        self.root.attributes("-alpha", 0.85)

        self.canvas = tk.Canvas(
            self.root,
            width=screen_w,
            height=screen_h,
            bg="black",
            highlightthickness=0,
        )
        self.canvas.pack()

        self.qr_images = []

        positions = {
            "TL": (MARGIN, MARGIN),
            "TR": (screen_w - MARGIN - MARKER_SIZE, MARGIN),
            "BL": (MARGIN, screen_h - MARGIN - MARKER_SIZE),
            "BR": (screen_w - MARGIN - MARKER_SIZE, screen_h - MARGIN - MARKER_SIZE),
        }

        for label, (x, y) in positions.items():
            pil_img = generate_qr(label, MARKER_SIZE)
            tk_img = ImageTk.PhotoImage(pil_img)
            self.qr_images.append(tk_img)
            self.canvas.create_image(x, y, anchor="nw", image=tk_img)

            # Label below/above the QR code
            label_y = y + MARKER_SIZE + 10 if "T" in label else y - 20
            self.canvas.create_text(
                x + MARKER_SIZE // 2,
                label_y,
                text=label,
                fill="white",
                font=("Helvetica", 14, "bold"),
            )

        self.canvas.create_text(
            screen_w // 2,
            screen_h // 2,
            text=f"Gaze Calibration\n{screen_w}x{screen_h}\nLook at each QR code\nPress ESC to close",
            fill="white",
            font=("Helvetica", 24, "bold"),
            justify="center",
        )

        self.root.bind("<Escape>", lambda e: self.root.destroy())
        self.root.bind("q", lambda e: self.root.destroy())
        self.root.bind("Q", lambda e: self.root.destroy())

    def run(self):
        print("[Calibration] Overlay active. Press ESC or Q to close.")
        self.root.mainloop()


if __name__ == "__main__":
    overlay = CalibrationOverlay()
    overlay.run()
