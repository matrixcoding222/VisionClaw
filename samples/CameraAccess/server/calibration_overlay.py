#!/usr/bin/env python3
"""
Calibration Overlay - Displays 4 large colored squares at screen corners.

Colors are chosen for easy detection even at low camera resolutions:
  TL = Red, TR = Green, BL = Blue, BR = Yellow

Usage:
  python calibration_overlay.py

Press Escape or Q to quit.
"""

import tkinter as tk

MARKER_SIZE = 300
MARGIN = 20

COLORS = {
    "TL": "#FF0000",  # Red
    "TR": "#00FF00",  # Green
    "BL": "#0000FF",  # Blue
    "BR": "#FFFF00",  # Yellow
}


class CalibrationOverlay:
    def __init__(self):
        self.root = tk.Tk()
        self.root.title("Gaze Calibration")
        self.root.attributes("-topmost", True)

        screen_w = self.root.winfo_screenwidth()
        screen_h = self.root.winfo_screenheight()

        self.root.geometry(f"{screen_w}x{screen_h}+0+0")
        self.root.configure(bg="black")
        self.root.attributes("-alpha", 0.9)

        self.canvas = tk.Canvas(
            self.root,
            width=screen_w,
            height=screen_h,
            bg="black",
            highlightthickness=0,
        )
        self.canvas.pack()

        positions = {
            "TL": (MARGIN, MARGIN),
            "TR": (screen_w - MARGIN - MARKER_SIZE, MARGIN),
            "BL": (MARGIN, screen_h - MARGIN - MARKER_SIZE),
            "BR": (screen_w - MARGIN - MARKER_SIZE, screen_h - MARGIN - MARKER_SIZE),
        }

        for label, (x, y) in positions.items():
            color = COLORS[label]
            self.canvas.create_rectangle(
                x, y, x + MARKER_SIZE, y + MARKER_SIZE,
                fill=color, outline=color,
            )

        self.canvas.create_text(
            screen_w // 2,
            screen_h // 2,
            text=f"Gaze Calibration\n{screen_w}x{screen_h}\n\nRed=TL  Green=TR\nBlue=BL  Yellow=BR\n\nPress ESC to close",
            fill="white",
            font=("Helvetica", 24, "bold"),
            justify="center",
        )

        self.root.bind("<Escape>", lambda e: self.root.destroy())
        self.root.bind("q", lambda e: self.root.destroy())
        self.root.bind("Q", lambda e: self.root.destroy())

    def run(self):
        print("[Calibration] Overlay active with colored squares.")
        print("[Calibration] TL=Red, TR=Green, BL=Blue, BR=Yellow")
        print("[Calibration] Press ESC or Q to close.")
        self.root.mainloop()


if __name__ == "__main__":
    overlay = CalibrationOverlay()
    overlay.run()
