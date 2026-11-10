"""Generate branding from the approved transparent raster, without redrawing it."""
import base64
import json
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'assets/branding/syntila_source.png'
SOURCE_DARK = ROOT / 'assets/branding/syntila_source_dark.png'
CHECK = '--check' in sys.argv
errors = []

def put(path, data):
    target = ROOT / path
    if CHECK:
        if not target.exists() or target.read_bytes() != data:
            errors.append(str(path))
    else:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)

def render(size, maskable=False, source=SOURCE):
    with tempfile.TemporaryDirectory() as tmp:
        output = pathlib.Path(tmp) / 'icon.png'
        inset = round(size * (0.60 if maskable else 0.90))
        subprocess.run(['magick', str(source), '-filter', 'Lanczos', '-resize', f'{inset}x{inset}',
                        '-background', '#121217' if maskable else 'none', '-gravity', 'center',
                        '-extent', f'{size}x{size}', '-strip', '-define', 'png:color-type=6', str(output)], check=True)
        return output.read_bytes()

def render_ios(size):
    with tempfile.TemporaryDirectory() as tmp:
        output = pathlib.Path(tmp) / 'icon.png'
        inset = round(size * 0.90)
        subprocess.run(['magick', str(SOURCE), '-filter', 'Lanczos', '-resize', f'{inset}x{inset}',
                        '-background', '#121217', '-gravity', 'center', '-extent', f'{size}x{size}',
                        '-alpha', 'remove', '-alpha', 'off', '-strip',
                        '-define', 'png:color-type=2', str(output)], check=True)
        return output.read_bytes()

# The asset catalog declares point sizes and scales; generate each unique PNG.
catalog = pathlib.Path('apps/app/ios/Runner/Assets.xcassets/AppIcon.appiconset')
if (ROOT / catalog / 'Contents.json').exists():
    entries = json.loads((ROOT / catalog / 'Contents.json').read_text())['images']
    generated = {}
    for entry in entries:
        filename = entry.get('filename')
        if filename:
            pixels = round(float(entry['size'].split('x')[0]) * int(entry['scale'][0]))
            if pixels not in generated:
                generated[pixels] = render_ios(pixels)
            put(catalog / filename, generated[pixels])
if '--ios-only' in sys.argv:
    if errors:
        sys.exit('Branding drift: ' + ', '.join(errors))
    print('iOS icons verified.' if CHECK else 'iOS icons generated.')
    sys.exit(0)

payload = base64.b64encode(SOURCE.read_bytes()).decode()
payload_dark = base64.b64encode((SOURCE_DARK if SOURCE_DARK.exists() else SOURCE).read_bytes()).decode()
image = f'<image href="data:image/png;base64,{payload}" x="64" y="64" width="1152" height="1152" preserveAspectRatio="xMidYMid meet"/>'
image_dark = f'<image href="data:image/png;base64,{payload_dark}" x="64" y="64" width="1152" height="1152" preserveAspectRatio="xMidYMid meet"/>'
svg = f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1280 1280">{image}</svg>\n'.encode()
svg_dark = f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1280 1280">{image_dark}</svg>\n'.encode()
assets = {name: svg for name in ['syntila_logo.svg', 'syntila_mark.svg', 'syntila_mark_monochrome.svg', 'syntila_mark_twotone.svg']}
assets['syntila_logo_dark.svg'] = svg_dark
assets['syntila_mark_dark.svg'] = svg_dark
for name, color, mark_image in [('syntila_wordmark.svg', '#1E2023', image), ('syntila_wordmark_dark.svg', '#EFEFF0', image_dark)]:
    assets[name] = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 460 96"><g transform="scale(.075)">{mark_image}</g><text x="106" y="62" font-family="Inter, Arial, sans-serif" font-size="40" font-weight="800" letter-spacing="0.06em" fill="{color}">SYNTILA</text></svg>\n').encode()
icons = {size: render(size, False, SOURCE) for size in [16, 32, 64, 128, 192, 256, 512, 1024]}
icons_dark = {size: render(size, False, SOURCE_DARK if SOURCE_DARK.exists() else SOURCE) for size in [32, 64, 128, 192, 512, 1024]}
assets['syntila_logo.png'] = icons[1024]
assets['syntila_logo_dark.png'] = icons_dark[1024]
assets['syntila_email_logo.png'] = icons[128]
for size in [32, 64, 128, 192, 512]:
    assets[f'syntila_logo_{size}.png'] = icons[size]
    assets[f'syntila_logo_dark_{size}.png'] = icons_dark[size]
for name, data in assets.items():
    put(f'assets/branding/{name}', data)
    for app in ['app', 'workspace', 'profile_lab']:
        put(f'apps/{app}/assets/branding/{name}', data)
    put(f'apps/site/public/{name}', data)
for app in ['workspace', 'profile_lab']:
    for size, data in icons.items():
        if size != 192:
            put(f'apps/{app}/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{size}.png', data)
put('apps/site/public/favicon.svg', svg)
put('apps/site/public/favicon.png', icons[32])
put('apps/app/web/syntila_logo.svg', svg)
put('apps/app/web/favicon.png', icons[32])
for size in [192, 512]:
    put(f'apps/app/web/icons/Icon-{size}.png', icons[size])
    put(f'apps/app/web/icons/Icon-maskable-{size}.png', render(size, True))
    put(f'apps/site/public/Icon-maskable-{size}.png', render(size, True))
with tempfile.TemporaryDirectory() as tmp:
    ico = pathlib.Path(tmp) / 'favicon.ico'
    subprocess.run(['magick', str(SOURCE), '-background', 'none', '-gravity', 'center', '-extent', '1268x1268', '-define', 'icon:auto-resize=64,48,32,16', str(ico)], check=True)
    for path in ['apps/site/public/favicon.ico', 'apps/app/web/favicon.ico']:
        put(path, ico.read_bytes())
# Preserve the existing social card design and replace its embedded logo.
import re
social = ROOT / 'apps/site/public/social-preview.svg'
content = social.read_text()
content = re.sub(r'<image\b[^>]*>', f'<image href="data:image/png;base64,{payload_dark}" x="72" y="68" width="48" height="48"/>', content)
put('apps/site/public/social-preview.svg', content.encode())
with tempfile.TemporaryDirectory() as tmp:
    source = pathlib.Path(tmp) / 'social.svg'
    output = pathlib.Path(tmp) / 'social.png'
    source.write_text(content.replace('Arial, sans-serif', '/System/Library/Fonts/Supplemental/Arial.ttf') if pathlib.Path('/System/Library/Fonts/Supplemental/Arial.ttf').exists() else content)
    subprocess.run(['magick', '-font', '/System/Library/Fonts/Supplemental/Arial.ttf' if pathlib.Path('/System/Library/Fonts/Supplemental/Arial.ttf').exists() else 'DejaVu-Sans', '-background', 'none', str(source), '-strip', str(output)], check=True)
    put('apps/site/public/social-preview.png', output.read_bytes())
if errors:
    sys.exit('Branding drift: ' + ', '.join(errors))
print('Branding derivatives verified.' if CHECK else 'Branding derivatives generated and synchronized.')
