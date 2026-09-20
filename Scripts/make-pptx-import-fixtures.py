from pathlib import Path
import zipfile, re, struct, zlib

# Deterministic, self-authored Office fixtures. No PowerPoint installation is required.
root = Path(__file__).resolve().parents[1] / 'BeanNotesTests' / 'ImportFixtures'
ns = 'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"'

def png():
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    rows = b''.join(b'\0' + b''.join(bytes((0, 180, 80) if x < 32 else (30, 90, 230)) for x in range(64)) for y in range(32))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 64, 32, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b'')

def fixture(name, width, height):
    W,H = int(width*914400), int(height*914400)
    def pos(x,y,w,h):
        return f'<a:xfrm><a:off x="{int(x*W)}" y="{int(y*H)}"/><a:ext cx="{int(w*W)}" cy="{int(h*H)}"/></a:xfrm>'
    def shape(i,x,y,w,h,text='',fill='FFFFFF',color='111111',sz=2400,rot=0):
        transform=pos(x,y,w,h).replace('<a:xfrm>',f'<a:xfrm rot="{rot}">')
        return f'<p:sp><p:nvSpPr><p:cNvPr id="{i}" name="Shape {i}"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr><p:spPr>{transform}<a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:solidFill><a:srgbClr val="{fill}"/></a:solidFill><a:ln><a:noFill/></a:ln></p:spPr><p:txBody><a:bodyPr wrap="square" lIns="0" rIns="0" tIns="0" bIns="0"/><a:lstStyle/><a:p><a:pPr/><a:r><a:rPr lang="en-US" sz="{sz}"><a:solidFill><a:srgbClr val="{color}"/></a:solidFill><a:latin typeface="Arial"/></a:rPr><a:t>{text}</a:t></a:r><a:endParaRPr lang="en-US"/></a:p></p:txBody></p:sp>'
    pic=f'<p:pic><p:nvPicPr><p:cNvPr id="8" name="Embedded test image"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed="rId2"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr>{pos(.55,.28,.38,.35)}<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>'
    with zipfile.ZipFile(root/'ThreePages.pptx') as original:
        files={n:original.read(n) for n in original.namelist()}
    files['ppt/presentation.xml']=re.sub(rb'<p:sldSz[^>]*/>',f'<p:sldSz cx="{W}" cy="{H}" type="custom"/>'.encode(),files['ppt/presentation.xml'])
    files['[Content_Types].xml']=files['[Content_Types].xml'].replace(b'</Types>',b'<Default Extension="png" ContentType="image/png"/></Types>')
    files['ppt/media/fixture.png']=png()
    for index, marker in enumerate(['First', 'Middle', 'Final'],1):
        content=shape(2,.04,.03,.92,.12,f'{marker} fidelity marker',sz=3000)
        content+=shape(3,.06,.28,.43,.33,'Text stays on the left. All these words must remain visible.',sz=2000)
        content+=pic
        content+=shape(4,0,0,.025,.025,fill='FF0000')
        content+=shape(5,.975,0,.025,.025,fill='FF0000')
        content+=shape(6,0,.975,.025,.025,fill='FF0000')
        content+=shape(7,.975,.975,.025,.025,fill='FF0000')
        content+=shape(9,.04,.82,.92,.12,f'{marker} bottom edge marker',fill='FFE080',sz=1800)
        content+=shape(10,.3,.67,.4,.08,'Rotated label',fill='FFFFFF',sz=1500,rot=900000)
        files[f'ppt/slides/slide{index}.xml']=f'<?xml version="1.0" encoding="UTF-8"?><p:sld {ns}><p:cSld><p:bg><p:bgPr><a:solidFill><a:srgbClr val="F0F4FF"/></a:solidFill><a:effectLst/></p:bgPr></p:bg><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>{content}</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>'.encode()
        rel=f'ppt/slides/_rels/slide{index}.xml.rels'
        files[rel]=files[rel].replace(b'</Relationships>',b'<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/fixture.png"/></Relationships>')
    with zipfile.ZipFile(root/f'{name}.pptx','w',zipfile.ZIP_DEFLATED) as dest:
        for path,data in files.items(): dest.writestr(path,data)
fixture('WidescreenFidelity', 13.333333, 7.5)
fixture('PortraitFidelity', 7.5, 10)

# A deck long enough to exercise offscreen slide resources and ordering.
with zipfile.ZipFile(root / 'WidescreenFidelity.pptx') as source:
    files = {name: source.read(name) for name in source.namelist()}
count = 24
files['ppt/presentation.xml'] = re.sub(
    rb'<p:sldIdLst>.*?</p:sldIdLst>',
    ('<p:sldIdLst>' + ''.join(f'<p:sldId id="{255+i}" r:id="rId{6+i}"/>' for i in range(1,count+1)) + '</p:sldIdLst>').encode(),
    files['ppt/presentation.xml'])
rels = files['ppt/_rels/presentation.xml.rels']
rels = re.sub(rb'<Relationship [^>]*Type="[^"]*/slide"[^>]*/>', b'', rels)
files['ppt/_rels/presentation.xml.rels'] = rels.replace(b'</Relationships>',
    (''.join(f'<Relationship Id="rId{6+i}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide{i}.xml"/>' for i in range(1,count+1)) + '</Relationships>').encode())
template_slide = files['ppt/slides/slide1.xml']
for index in range(1,count+1):
    files[f'ppt/slides/slide{index}.xml'] = template_slide.replace(b'First', f'Slide {index:02d}'.encode())
    files[f'ppt/slides/_rels/slide{index}.xml.rels'] = files['ppt/slides/_rels/slide1.xml.rels']
    if index > 3:
        files['[Content_Types].xml'] = files['[Content_Types].xml'].replace(b'</Types>',
            f'<Override PartName="/ppt/slides/slide{index}.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/></Types>'.encode())
with zipfile.ZipFile(root / 'LongFidelity.pptx', 'w', zipfile.ZIP_DEFLATED) as output:
    for name, data in files.items():
        output.writestr(name, data)
