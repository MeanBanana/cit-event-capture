import base64, io, json, os
from playwright.sync_api import sync_playwright
from PIL import Image
V=os.path.dirname(os.path.abspath(__file__)); OUT=f"{V}/out"
os.makedirs(f"{OUT}/layers/d",exist_ok=True); os.makedirs(f"{OUT}/layers/m",exist_ok=True); os.makedirs(f"{OUT}/media/cards",exist_ok=True)
def img(url): return Image.open(io.BytesIO(base64.b64decode(url.split(',',1)[1])))
LAYERS=['sky','van','ambush','frame','phone','ground']
with sync_playwright() as p:
    b=p.chromium.launch(); pg=b.new_page(); pg.goto(f"file://{V}/render.html"); pg.wait_for_function("window.ready===true"); pg.evaluate("document.fonts.ready")
    comp={}
    for cut in 'dm':
        base=None
        for L in LAYERS:
            im=img(pg.evaluate(f"paintLayer('{L}','{cut}')")).convert('RGBA')
            im.save(f"{OUT}/layers/{cut}/{L}.webp",quality=82,method=6)
            base=im if base is None else Image.alpha_composite(base,im)
        comp[cut]=base; base.convert('RGB').save(f"{OUT}/comp_{cut}.jpg",quality=88)
    json.dump(pg.evaluate("window.BOXES"),open(f"{OUT}/boxes.json","w"),indent=1)
    for n in (1,2,4):
        img(pg.evaluate(f"still({n})")).convert('RGB').save(f"{OUT}/media/cards/s{n}.webp",quality=84)
    b.close()
# card 3 is the witness view, cropped out of the mobile composite
m=comp['m'].convert('RGB'); W,H=m.size; ch=int(W*4/3); top=H-ch-int(H*0.0)
m.crop((0,H-ch,W,H)).resize((840,1120),Image.LANCZOS).save(f"{OUT}/media/cards/s3.webp",quality=84)
comp['d'].convert('RGB').resize((1200,679),Image.LANCZOS).crop((0,25,1200,655)).save(f"{OUT}/media/og.jpg",quality=85)
print("ok")
