/**
 * SFColor — total, never-throwing colour maths for brand-driven email.
 *
 * An admin may type ANY value into the SignForce_Branding__c colour fields
 * (they are Text, not Url/colour-validated). Every method here is defensive:
 * a bad value yields null (so the caller keeps its default) and no method
 * ever throws, because these run in guest context inside a swallowed try.
 *
 * The output of these helpers is always a literal 6-digit hex or an rgba()
 * string — email clients (Outlook/Gmail) do not honour CSS variables, so the
 * brand tokens must resolve to literals at build time.
 *
 * Numeric types: ratios/thresholds are Decimal because that is what an Apex
 * literal like 0.30 actually is. Double appears only inside luminance(), where
 * Math.pow demands it.
 *
 * Apex has no radix parse (Integer.valueOf(String) takes no base), so hex
 * nibbles are read by hand via HEXCHARS.indexOf.
 */
public with sharing class SFColor {

    private static final String HEXCHARS = '0123456789abcdef';
    public static final Integer[] WHITE = new Integer[]{ 255, 255, 255 };
    public static final Integer[] NAVY  = new Integer[]{ 10, 22, 40 };   // #0a1628
    public static final Integer[] BLACK = new Integer[]{ 0, 0, 0 };

    // sRGB -> linear constants, held as Double so Math.pow resolves.
    private static final Double LIN_KNEE  = 0.03928;
    private static final Double LIN_DIV   = 12.92;
    private static final Double LIN_OFF   = 0.055;
    private static final Double LIN_SCALE = 1.055;
    private static final Double LIN_GAMMA = 2.4;

    // CSS Level-1 named colours that fit the Text(7) field ('magenta' is 7 chars).
    private static final Map<String, String> NAMED = new Map<String, String>{
        'white' => 'ffffff', 'black' => '000000', 'red' => 'ff0000', 'lime' => '00ff00',
        'blue' => '0000ff', 'yellow' => 'ffff00', 'aqua' => '00ffff', 'cyan' => '00ffff',
        'fuchsia' => 'ff00ff', 'magenta' => 'ff00ff', 'silver' => 'c0c0c0', 'gray' => '808080',
        'grey' => '808080', 'maroon' => '800000', 'olive' => '808000', 'green' => '008000',
        'purple' => '800080', 'teal' => '008080', 'navy' => '000080', 'orange' => 'ffa500'
    };

    /** TOTAL. Returns null when the input is unusable so the caller falls back
     *  to its own default. Never throws. Named lookup happens BEFORE 3-digit
     *  expansion so 'red' resolves via the map rather than expanding to a bad
     *  'rreedd'. */
    public static Integer[] parse(String raw) {
        if (String.isBlank(raw)) return null;
        String s = raw.trim().toLowerCase();
        if (s.startsWith('#')) s = s.substring(1);
        if (NAMED.containsKey(s)) s = NAMED.get(s);
        if (s.length() == 3) {                                  // #abc -> aabbcc
            s = s.substring(0, 1) + s.substring(0, 1)
              + s.substring(1, 2) + s.substring(1, 2)
              + s.substring(2, 3) + s.substring(2, 3);
        }
        if (s.length() != 6) return null;
        Integer r = byteAt(s, 0), g = byteAt(s, 2), b = byteAt(s, 4);
        if (r < 0 || g < 0 || b < 0) return null;
        return new Integer[]{ r, g, b };
    }

    private static Integer byteAt(String s, Integer i) {
        Integer hi = HEXCHARS.indexOf(s.substring(i, i + 1));
        Integer lo = HEXCHARS.indexOf(s.substring(i + 1, i + 2));
        return (hi < 0 || lo < 0) ? -1 : (hi * 16 + lo);
    }

    public static String toHex(Integer[] c) {
        return '#' + nib(c[0]) + nib(c[1]) + nib(c[2]);
    }
    private static String nib(Integer v) {
        Integer x = Math.max(0, Math.min(255, v));
        return HEXCHARS.substring(x / 16, x / 16 + 1)
             + HEXCHARS.substring(Math.mod(x, 16), Math.mod(x, 16) + 1);
    }
    public static String toRgba(Integer[] c, Decimal a) {
        return 'rgba(' + c[0] + ',' + c[1] + ',' + c[2] + ',' + a + ')';
    }

    // ── WCAG 2.1 relative luminance / contrast ──
    private static Double lin(Integer c) {
        Double v = Double.valueOf(c) / 255;
        return (v <= LIN_KNEE) ? (v / LIN_DIV)
                               : Math.pow((v + LIN_OFF) / LIN_SCALE, LIN_GAMMA);
    }
    public static Double luminance(Integer[] c) {
        return 0.2126 * lin(c[0]) + 0.7152 * lin(c[1]) + 0.0722 * lin(c[2]);
    }
    public static Double contrast(Integer[] a, Integer[] b) {
        Double la = luminance(a), lb = luminance(b);
        Double hi = (la > lb) ? la : lb;
        Double lo = (la > lb) ? lb : la;
        return (hi + 0.05) / (lo + 0.05);
    }

    /** The load-bearing primitive: pick a glyph/text colour that clears AA
     *  (>=4.5:1) on any background. white covers L<=0.1833 and black covers
     *  L>=0.175 — the ranges overlap, so white+black alone are total; navy is
     *  preferred when it qualifies purely for brand consistency. */
    public static Integer[] inkFor(Integer[] bg) {
        if (contrast(bg, WHITE) >= 4.5) return WHITE;
        if (contrast(bg, NAVY)  >= 4.5) return NAVY;
        return BLACK;
    }

    /** Darken toward black until luminance <= maxL. 12 fixed bisections
     *  (resolution 1/4096); luminance is monotone under darkening so the
     *  bisection is sound. No-op when already dark enough. */
    public static Integer[] clampMaxLum(Integer[] c, Decimal maxL) {
        if (luminance(c) <= maxL) return c;
        Decimal lo = 0, hi = 1;
        Integer[] best = BLACK;
        for (Integer i = 0; i < 12; i++) {
            Decimal t = (lo + hi) / 2;
            Integer[] cand = mix(c, BLACK, t);
            if (luminance(cand) > maxL) { lo = t; } else { hi = t; best = cand; }
        }
        return best;
    }

    /** Darken c toward black until contrast(c,bg) >= target. Sound only when bg
     *  is the lighter of the pair (our tints always are). */
    public static Integer[] inkOn(Integer[] c, Integer[] bg, Decimal target) {
        if (contrast(c, bg) >= target) return c;
        Decimal lo = 0, hi = 1;
        Integer[] best = null;
        for (Integer i = 0; i < 12; i++) {
            Decimal t = (lo + hi) / 2;
            Integer[] cand = mix(c, BLACK, t);
            if (contrast(cand, bg) < target) { lo = t; } else { hi = t; best = cand; }
        }
        return (best == null) ? NAVY : best;
    }

    public static Integer[] mix(Integer[] a, Integer[] b, Decimal t) {
        return new Integer[]{
            chan(a[0], b[0], t), chan(a[1], b[1], t), chan(a[2], b[2], t)
        };
    }
    private static Integer chan(Integer x, Integer y, Decimal t) {
        Decimal v = x + (y - x) * t;
        return Math.max(0, Math.min(255, v.round().intValue()));
    }
    public static Integer[] shade(Integer[] c, Decimal w) { return mix(c, BLACK, w); }
    public static Integer[] tint (Integer[] c, Decimal w) { return mix(c, WHITE, w); }

    /** Only https logos are interpolated into an <img src>; anything else
     *  (http, /resource, javascript:, data:) falls back to the monogram. */
    public static Boolean isSafeLogoUrl(String u) {
        return String.isNotBlank(u) && u.trim().toLowerCase().startsWith('https://');
    }
}