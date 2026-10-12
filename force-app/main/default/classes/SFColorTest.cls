/**
 * SFColorTest — exhaustive edge coverage for the brand-email colour maths.
 * The parser must be TOTAL (never throw, null on junk) and every derived
 * colour must clear WCAG contrast for an arbitrary admin-chosen hex.
 */
@isTest(SeeAllData=false)
private class SFColorTest {

    @isTest
    static void parse_handlesEveryShape() {
        Assert.areEqual(null, SFColor.parse(null), 'null -> null');
        Assert.areEqual(null, SFColor.parse(''), 'empty -> null');
        Assert.areEqual(null, SFColor.parse('   '), 'blank -> null');

        Assert.areEqual('#0a1628', SFColor.toHex(SFColor.parse('0a1628')), 'no #');
        Assert.areEqual('#0a1628', SFColor.toHex(SFColor.parse('#0A1628')), 'uppercase');
        Assert.areEqual('#f59e0b', SFColor.toHex(SFColor.parse('  #f59e0b  ')), 'surrounding spaces');
        Assert.areEqual('#aabbcc', SFColor.toHex(SFColor.parse('#abc')), '3-digit expands');
        Assert.areEqual('#ffffff', SFColor.toHex(SFColor.parse('FFF')), '3-digit upper no #');

        // named colours
        Assert.areEqual('#ff0000', SFColor.toHex(SFColor.parse('red')));
        Assert.areEqual('#000080', SFColor.toHex(SFColor.parse('navy')));
        Assert.areEqual('#ff00ff', SFColor.toHex(SFColor.parse('magenta')));

        // junk -> null (caller keeps default)
        Assert.areEqual(null, SFColor.parse('banana!'), '7 chars, not hex');
        Assert.areEqual(null, SFColor.parse('#gg0011'), 'non-hex nibble');
        Assert.areEqual(null, SFColor.parse('rgb(1,2,3)'), 'wrong length');
        Assert.areEqual(null, SFColor.parse('#12345'), '5 chars');
    }

    @isTest
    static void inkFor_alwaysClearsAA() {
        // Sweep the whole grey axis incl. the mid-tone dead band (~#767676)
        // where neither white nor navy alone is obvious; inkFor must still find
        // a >=4.5:1 ink for every one.
        for (Integer v = 0; v <= 255; v += 5) {
            Integer[] bg = new Integer[]{ v, v, v };
            Integer[] ink = SFColor.inkFor(bg);
            Assert.isTrue(SFColor.contrast(bg, ink) >= 4.5,
                'inkFor must clear AA for grey ' + v + ' (got ' + SFColor.contrast(bg, ink) + ')');
        }
        // A vivid mid hue too
        Integer[] teal = SFColor.parse('#1d9e75');
        Assert.isTrue(SFColor.contrast(teal, SFColor.inkFor(teal)) >= 4.5);
    }

    @isTest
    static void clampMaxLum_darkensPaleColours() {
        // A near-white primary must clamp to something dark enough to read as a
        // button fill against the white card (>=3:1), i.e. luminance <= 0.30.
        Integer[] pale = SFColor.parse('#fafafa');
        Integer[] clamped = SFColor.clampMaxLum(pale, 0.30);
        Assert.isTrue(SFColor.luminance(clamped) <= 0.30, 'clamped luminance <= 0.30');
        Assert.isTrue(SFColor.contrast(clamped, SFColor.WHITE) >= 3.0, 'button visible on white');

        // Already-dark colour is returned unchanged.
        Integer[] navy = SFColor.parse('#0a1628');
        Assert.areEqual('#0a1628', SFColor.toHex(SFColor.clampMaxLum(navy, 0.30)), 'no-op when dark');
    }

    @isTest
    static void inkOn_darkensUntilReadable() {
        Integer[] surface = SFColor.parse('#fffbeb');       // pale amber tint
        Integer[] pale    = SFColor.parse('#fffef0');       // barely-there text
        Integer[] ink     = SFColor.inkOn(pale, surface, 4.5);
        Assert.isTrue(SFColor.contrast(ink, surface) >= 4.5, 'inkOn reaches AA on the tint');
    }

    @isTest
    static void extremes_blackAndWhiteAndLogoGuard() {
        Assert.areEqual('#000000', SFColor.toHex(SFColor.parse('#000000')));
        Assert.areEqual('#ffffff', SFColor.toHex(SFColor.parse('#ffffff')));
        // white primary clamps to a dark, readable fill
        Integer[] whiteFill = SFColor.clampMaxLum(SFColor.parse('#ffffff'), 0.30);
        Assert.isTrue(SFColor.contrast(whiteFill, SFColor.WHITE) >= 3.0);

        Assert.isTrue(SFColor.isSafeLogoUrl('https://x.example.com/l.png'));
        Assert.isFalse(SFColor.isSafeLogoUrl('http://x.example.com/l.png'), 'http rejected');
        Assert.isFalse(SFColor.isSafeLogoUrl('/resource/logo'), 'relative rejected');
        Assert.isFalse(SFColor.isSafeLogoUrl('javascript:alert(1)'), 'js scheme rejected');
        Assert.isFalse(SFColor.isSafeLogoUrl(null));
    }

    @isTest
    static void mixAndRgba_areSane() {
        Assert.areEqual('#808080', SFColor.toHex(SFColor.mix(SFColor.BLACK, SFColor.WHITE, 0.5)), 'midpoint');
        Assert.areEqual('rgba(10,22,40,0.2)', SFColor.toRgba(SFColor.NAVY, 0.2));
    }
}