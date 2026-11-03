package icons

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"image"
	"image/color"
	_ "image/gif" // register decoders
	_ "image/jpeg"
	"image/png"
	"strings"
)

// MaxEdge is the largest edge an icon is stored at; bigger images are
// downscaled (the UI draws them at 14–32 logical px).
const MaxEdge = 128

var (
	errSVG          = errors.New("svg icons are not supported")
	errNotImage     = errors.New("not an image")
	errTooSmall     = errors.New("icon too small")
	errUnsupported  = errors.New("unsupported image format")
	pngMagic        = []byte("\x89PNG\r\n\x1a\n")
	icoMagic        = []byte{0, 0, 1, 0}
	webpRIFF, webpW = []byte("RIFF"), []byte("WEBP")
)

// Normalize turns fetched icon bytes into something the UI can draw:
// PNG/JPEG/GIF/ICO become a PNG at most MaxEdge px square-ish; WebP passes
// through (Flutter decodes it); SVG is rejected.
func Normalize(data []byte) (out []byte, contentType string, err error) {
	switch {
	case len(data) == 0:
		return nil, "", errNotImage
	case looksSVG(data):
		return nil, "", errSVG
	case len(data) > 12 && bytes.Equal(data[:4], webpRIFF) && bytes.Equal(data[8:12], webpW):
		return data, "image/webp", nil
	}
	var img image.Image
	if bytes.HasPrefix(data, icoMagic) {
		img, err = decodeICO(data)
	} else {
		img, _, err = image.Decode(bytes.NewReader(data))
		if err != nil {
			err = fmt.Errorf("%w: %v", errNotImage, err)
		}
	}
	if err != nil {
		return nil, "", err
	}
	b := img.Bounds()
	if b.Dx() < 12 || b.Dy() < 12 {
		return nil, "", errTooSmall
	}
	// Small PNGs pass through untouched.
	if bytes.HasPrefix(data, pngMagic) && b.Dx() <= MaxEdge && b.Dy() <= MaxEdge {
		return data, "image/png", nil
	}
	img = downscale(img, MaxEdge)
	var buf bytes.Buffer
	if err := (&png.Encoder{CompressionLevel: png.BestCompression}).Encode(&buf, img); err != nil {
		return nil, "", err
	}
	return buf.Bytes(), "image/png", nil
}

func looksSVG(data []byte) bool {
	head := strings.ToLower(string(data[:min(len(data), 512)]))
	return strings.Contains(head, "<svg") || (strings.HasPrefix(strings.TrimSpace(head), "<?xml") && !strings.Contains(head, "<html"))
}

// downscale box-filters img so its longest edge is at most edge.
func downscale(img image.Image, edge int) image.Image {
	b := img.Bounds()
	w, h := b.Dx(), b.Dy()
	if w <= edge && h <= edge {
		return img
	}
	dw, dh := edge, edge
	if w > h {
		dh = max(1, h*edge/w)
	} else {
		dw = max(1, w*edge/h)
	}
	src := image.NewNRGBA(b)
	for y := b.Min.Y; y < b.Max.Y; y++ {
		for x := b.Min.X; x < b.Max.X; x++ {
			src.Set(x, y, img.At(x, y))
		}
	}
	dst := image.NewNRGBA(image.Rect(0, 0, dw, dh))
	for dy := 0; dy < dh; dy++ {
		y0, y1 := dy*h/dh, max((dy+1)*h/dh, dy*h/dh+1)
		for dx := 0; dx < dw; dx++ {
			x0, x1 := dx*w/dw, max((dx+1)*w/dw, dx*w/dw+1)
			// Alpha-weighted average so transparent pixels don't darken edges.
			var r, g, bl, a, n uint64
			for y := y0; y < y1; y++ {
				for x := x0; x < x1; x++ {
					p := src.NRGBAAt(b.Min.X+x, b.Min.Y+y)
					pa := uint64(p.A)
					r += uint64(p.R) * pa
					g += uint64(p.G) * pa
					bl += uint64(p.B) * pa
					a += pa
					n++
				}
			}
			if a == 0 {
				continue
			}
			dst.SetNRGBA(dx, dy, color.NRGBA{R: uint8(r / a), G: uint8(g / a), B: uint8(bl / a), A: uint8(a / n)})
		}
	}
	return dst
}

// decodeICO picks the largest image in a .ico file: an embedded PNG, or a
// BMP (DIB) entry at 1/4/8/24/32 bits per pixel.
func decodeICO(data []byte) (image.Image, error) {
	if len(data) < 6 {
		return nil, errNotImage
	}
	n := int(binary.LittleEndian.Uint16(data[4:6]))
	if n == 0 || 6+16*n > len(data) {
		return nil, errNotImage
	}
	type entry struct{ size, off, length int }
	var best *entry
	for i := 0; i < n; i++ {
		e := data[6+16*i : 6+16*(i+1)]
		w := int(e[0])
		if w == 0 {
			w = 256
		}
		ent := entry{size: w, length: int(binary.LittleEndian.Uint32(e[8:12])), off: int(binary.LittleEndian.Uint32(e[12:16]))}
		if ent.off < 0 || ent.length <= 0 || ent.off+ent.length > len(data) {
			continue
		}
		if best == nil || ent.size > best.size {
			best = &ent
		}
	}
	if best == nil {
		return nil, errNotImage
	}
	payload := data[best.off : best.off+best.length]
	if bytes.HasPrefix(payload, pngMagic) {
		return png.Decode(bytes.NewReader(payload))
	}
	return decodeDIB(payload)
}

// decodeDIB decodes an ICO's BITMAPINFOHEADER image (XOR bitmap followed by
// the 1bpp AND transparency mask; the header height is doubled).
func decodeDIB(d []byte) (image.Image, error) {
	if len(d) < 40 {
		return nil, errNotImage
	}
	le := binary.LittleEndian
	hdr := int(le.Uint32(d[0:4]))
	w := int(int32(le.Uint32(d[4:8])))
	h := int(int32(le.Uint32(d[8:12]))) / 2
	bpp := int(le.Uint16(d[14:16]))
	comp := le.Uint32(d[16:20])
	clrUsed := int(le.Uint32(d[32:36]))
	if hdr < 40 || w <= 0 || h <= 0 || w > 1024 || h > 1024 || (comp != 0 && comp != 3) {
		return nil, errUnsupported
	}
	off := hdr
	if comp == 3 && hdr == 40 {
		off += 12 // BI_BITFIELDS masks follow a v1 header
	}
	var palette []color.NRGBA
	if bpp <= 8 {
		nc := clrUsed
		if nc == 0 {
			nc = 1 << bpp
		}
		if off+4*nc > len(d) {
			return nil, errNotImage
		}
		for i := 0; i < nc; i++ {
			p := d[off+4*i:]
			palette = append(palette, color.NRGBA{R: p[2], G: p[1], B: p[0], A: 255})
		}
		off += 4 * nc
	}
	switch bpp {
	case 1, 4, 8, 24, 32:
	default:
		return nil, errUnsupported
	}
	stride := (w*bpp + 31) / 32 * 4
	maskStride := (w + 31) / 32 * 4
	if off+stride*h > len(d) {
		return nil, errNotImage
	}
	maskOff := off + stride*h
	hasMask := maskOff+maskStride*h <= len(d)
	img := image.NewNRGBA(image.Rect(0, 0, w, h))
	anyAlpha := false
	for row := 0; row < h; row++ {
		y := h - 1 - row // bottom-up
		line := d[off+row*stride:]
		for x := 0; x < w; x++ {
			var c color.NRGBA
			switch bpp {
			case 32:
				c = color.NRGBA{R: line[4*x+2], G: line[4*x+1], B: line[4*x], A: line[4*x+3]}
				if c.A != 0 {
					anyAlpha = true
				}
			case 24:
				c = color.NRGBA{R: line[3*x+2], G: line[3*x+1], B: line[3*x], A: 255}
			default:
				bitsPer := bpp
				bit := x * bitsPer
				v := int(line[bit/8]>>(8-bitsPer-bit%8)) & (1<<bitsPer - 1)
				if v < len(palette) {
					c = palette[v]
				}
			}
			img.SetNRGBA(x, y, c)
		}
	}
	if bpp == 32 && !anyAlpha && !hasMask {
		for i := 3; i < len(img.Pix); i += 4 {
			img.Pix[i] = 255
		}
	}
	// The AND mask decides transparency unless 32bpp carries real alpha.
	if hasMask && (bpp != 32 || !anyAlpha) {
		for row := 0; row < h; row++ {
			y := h - 1 - row
			line := d[maskOff+row*maskStride:]
			for x := 0; x < w; x++ {
				transparent := line[x/8]>>(7-x%8)&1 == 1
				p := img.NRGBAAt(x, y)
				if transparent {
					p.A = 0
				} else {
					p.A = 255
				}
				img.SetNRGBA(x, y, p)
			}
		}
	}
	return img, nil
}
