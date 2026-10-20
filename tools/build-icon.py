#!/usr/bin/env python3
"""Genera el icono de ai-progress (assets/ai-progress.ico + .png).

Se dibuja a 1024 px y se reduce con antialias para que las versiones chicas
(16/32 px, las que usa la bandeja) queden nitidas.
"""
import os

from PIL import Image, ImageDraw

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(BASE, 'assets')

FONDO = (23, 27, 36, 255)
BORDE = (58, 65, 82, 255)
BARRAS = [
    (0.22, 0.30, 0.56, (74, 222, 128, 255)),   # verde
    (0.22, 0.46, 0.44, (251, 191, 36, 255)),   # ambar
    (0.22, 0.62, 0.32, (248, 113, 113, 255)),  # rojo
]


def dibujar(lado=1024):
    imagen = Image.new('RGBA', (lado, lado), (0, 0, 0, 0))
    dibujo = ImageDraw.Draw(imagen)
    margen = lado * 0.02
    radio = lado * 0.22
    dibujo.rounded_rectangle(
        (margen, margen, lado - margen, lado - margen),
        radius=radio, fill=FONDO, outline=BORDE, width=max(2, lado // 96))
    alto = lado * 0.09
    for x, y, ancho, color in BARRAS:
        caja = (lado * x, lado * y, lado * (x + ancho), lado * y + alto)
        dibujo.rounded_rectangle(caja, radius=alto / 2, fill=color)
    return imagen


def main():
    os.makedirs(ASSETS, exist_ok=True)
    grande = dibujar(1024)
    png = os.path.join(ASSETS, 'ai-progress.png')
    grande.resize((256, 256), Image.LANCZOS).save(png)

    ico = os.path.join(ASSETS, 'ai-progress.ico')
    tamanos = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
    grande.save(ico, format='ICO', sizes=tamanos)
    print('ok %s (%d B)' % (ico, os.path.getsize(ico)))
    print('ok %s (%d B)' % (png, os.path.getsize(png)))


if __name__ == '__main__':
    main()
