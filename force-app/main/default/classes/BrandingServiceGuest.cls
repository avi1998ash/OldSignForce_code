/**
 * @description : BrandingServiceGuest - guest-side copy of BrandingService
 * @author      : SignForce
 *
 * Branded email header / footer / block builders and the signing-page branding map, for the
 * GUEST signing flows (AgreementServiceGuest, AgreementControllerGuest, GuestSigningApi,
 * OTPService). Internal callers use BrandingService.
 *
 * SHARING: `with sharing`. This class reads only the SignForce_Branding__c custom setting
 * (getOrgDefaults) and builds strings: it does no SOQL or DML, so the sharing keyword has no
 * effect on what it returns for either audience.
 *
 * Every method here is a verbatim copy of the BrandingService method of the same name, except
 * that getBrandingForLWC and codeBlock live ONLY here (they were guest-only and have been moved
 * out of BrandingService). BrandingService.infoCard is internal-only and is not copied.
 * See BrandingService for the full description of the colour-token model.
 */
public with sharing class BrandingServiceGuest {

    // Hardcoded defaults - always available even if Custom Setting fails
    private static final String DEFAULT_COMPANY = 'eSignforce';

    private static final String DEFAULT_PRIMARY = '#0a1628';

    // Brand indigo — matches the product's accent rail (signforceConfirm) and the
    // document-editor signer palette, so email + app read as one theme out of the
    // box. Any org can still override this in the SignForce Branding setting.
    private static final String DEFAULT_ACCENT  = '#6366f1';

    private static final String DEFAULT_FOOTER  = 'Powered by eSignforce - Secure eSignature Platform';

    private static Map<String, String> cachedBranding;

    private static Map<String, String> cachedTokens;

    /**
     * Get branding as a simple map - safe for all contexts.
     * NOTE: frozen contract — the 7 keys and their names are read by the LWC
     * signing page and ~20 test assertions across the package. Values only.
     */
    public static Map<String, String> getBrandingMap() {
        if (cachedBranding != null) return cachedBranding.clone();

        cachedBranding = new Map<String, String>();
        cachedBranding.put('companyName', DEFAULT_COMPANY);
        cachedBranding.put('primaryColor', DEFAULT_PRIMARY);
        cachedBranding.put('accentColor', DEFAULT_ACCENT);
        cachedBranding.put('emailHeaderColor', DEFAULT_PRIMARY);
        cachedBranding.put('footerText', DEFAULT_FOOTER);
        cachedBranding.put('signingPageTitle', DEFAULT_COMPANY);
        cachedBranding.put('logoUrl', '');

        // Try to load Custom Setting (may fail for guest users)
        try {
            SignForce_Branding__c settings = SignForce_Branding__c.getOrgDefaults();
            if (settings != null && settings.Id != null) {
                if (String.isNotBlank(settings.Company_Name__c))
                    cachedBranding.put('companyName', settings.Company_Name__c);
                if (String.isNotBlank(settings.Primary_Color__c))
                    cachedBranding.put('primaryColor', settings.Primary_Color__c);
                if (String.isNotBlank(settings.Accent_Color__c))
                    cachedBranding.put('accentColor', settings.Accent_Color__c);
                if (String.isNotBlank(settings.Email_Header_Color__c))
                    cachedBranding.put('emailHeaderColor', settings.Email_Header_Color__c);
                if (String.isNotBlank(settings.Email_Footer_Text__c))
                    cachedBranding.put('footerText', settings.Email_Footer_Text__c);
                if (String.isNotBlank(settings.Signing_Page_Title__c))
                    cachedBranding.put('signingPageTitle', settings.Signing_Page_Title__c);
                if (String.isNotBlank(settings.Logo_URL__c))
                    cachedBranding.put('logoUrl', settings.Logo_URL__c);
            }
        } catch(Exception e) {
            System.debug('BrandingService: Custom Setting not accessible, using defaults. ' + e.getMessage());
        }

        return cachedBranding.clone();
    }

    /**
     * The single data entry point for every email colour. Seeds the whole
     * palette with the hand-tuned SignForce literals FIRST (so a guest-context
     * failure still yields a complete, correct map), then re-derives the
     * brand-driven subset from the custom setting. Transaction-cached; returns
     * a defensive copy. Never throws.
     */
    public static Map<String, String> getEmailTokens() {
        if (cachedTokens != null) return cachedTokens.clone();

        Map<String, String> t = seedDefaultTokens();

        try {
            Map<String, String> b = getBrandingMap();
            t.put('companyName', b.get('companyName'));
            t.put('footerText',  b.get('footerText'));
            t.put('logoUrl',     b.get('logoUrl'));

            // Primary — only re-derive when the admin actually changed it, so
            // an untouched org stays byte-identical to the seeded literals.
            Integer[] pri = SFColor.parse(b.get('primaryColor'));
            if (pri != null && SFColor.toHex(pri) != DEFAULT_PRIMARY) applyPrimary(t, pri);

            Integer[] acc = SFColor.parse(b.get('accentColor'));
            if (acc != null && SFColor.toHex(acc) != DEFAULT_ACCENT) applyAccent(t, acc);

            // Header band — an explicit, non-default header colour overrides the
            // primary-derived headerBg; otherwise the header follows the primary.
            Integer[] hdr = SFColor.parse(b.get('emailHeaderColor'));
            if (hdr != null && SFColor.toHex(hdr) != DEFAULT_PRIMARY) {
                Integer[] clamped = SFColor.clampMaxLum(hdr, 0.30);
                t.put('headerBg', SFColor.toHex(clamped));
                t.put('headerBgText', SFColor.toHex(SFColor.inkFor(clamped)));
            }
        } catch (Exception e) {
            System.debug('BrandingServiceGuest.getEmailTokens: falling back to defaults. ' + e.getMessage());
        }

        cachedTokens = t;
        return cachedTokens.clone();
    }

    /** Reset both caches. Test-only: the static caches would otherwise serve a
     *  stale palette to an assertion made after a mid-test branding insert. */
    @TestVisible
    private static void clearCache() {
        cachedBranding = null;
        cachedTokens = null;
    }

    private static Map<String, String> seedDefaultTokens() {
        Map<String, String> t = new Map<String, String>{
            'companyName' => DEFAULT_COMPANY,
            'footerText'  => DEFAULT_FOOTER,
            'logoUrl'     => '',
            // Primary (navy) literals — the header band and CTA. Kept as literals
            // because primary never moves off DEFAULT_PRIMARY unless the admin sets it.
            'brandPrimary'  => '#0a1628',
            'brandFill'     => '#0a1628',
            'brandFillInk'  => '#ffffff',
            'ctaShadow'     => 'rgba(10,22,40,0.20)',
            'headerBg'      => '#0a1628',
            'headerBgText'  => '#ffffff',
            'link'          => '#2563eb',
            // fixed neutrals
            'text'        => '#0f172a',
            'textSub'     => '#475569',
            'textHelper'  => '#64748b',
            'textMuted'   => '#94a3b8',
            'textQuote'   => '#1f2937',
            'cardBorder'  => '#eef0f3',
            'cardFill'    => '#f9fafb',
            'surface'     => '#ffffff',
            'surfaceAlt'  => '#fbfbfc',
            'canvas'      => '#f6f7f9',
            'shellBorder' => '#eaecef',
            // fixed semantics (never brand-derived — red must stay "bad")
            'dangerSurface' => '#fef2f2', 'dangerBorder' => '#fecaca', 'dangerText' => '#991b1b', 'dangerDot' => '#dc2626',
            'successSurface'=> '#ecfdf5', 'successBorder'=> '#a7f3d0', 'successText'=> '#065f46', 'successDot'=> '#10b981', 'successGlyph'=> '#059669',
            'neutralSurface'=> '#f3f4f6', 'neutralBorder'=> '#e5e7eb', 'neutralText'=> '#374151', 'neutralDot'=> '#6b7280'
        };
        // Accent tokens (pill, top hairline, reminder CTA) are derived from the one
        // DEFAULT_ACCENT constant rather than carried as literals, so the seeded
        // palette and an admin-set accent go through the exact same colour math.
        applyAccent(t, SFColor.parse(DEFAULT_ACCENT));
        return t;
    }

    private static void applyPrimary(Map<String, String> t, Integer[] pri) {
        Integer[] fill = SFColor.clampMaxLum(pri, 0.30);    // >=3:1 shape-vs-card
        t.put('brandPrimary', SFColor.toHex(pri));
        t.put('brandFill', SFColor.toHex(fill));
        t.put('brandFillInk', SFColor.toHex(SFColor.inkFor(fill)));
        t.put('ctaShadow', SFColor.toRgba(fill, 0.20));
        t.put('headerBg', SFColor.toHex(fill));
        t.put('headerBgText', SFColor.toHex(SFColor.inkFor(fill)));
        t.put('link', SFColor.toHex(SFColor.clampMaxLum(pri, 0.1833)));  // AA on white card
    }

    private static void applyAccent(Map<String, String> t, Integer[] acc) {
        Integer[] surface = SFColor.mix(acc, SFColor.WHITE, 0.94);
        Integer[] warnBg  = SFColor.clampMaxLum(SFColor.shade(acc, 0.12), 0.30);
        t.put('brandAccent', SFColor.toHex(acc));
        t.put('brandHairline', SFColor.toHex(SFColor.clampMaxLum(acc, 0.55)));
        t.put('warnDot', SFColor.toHex(acc));
        t.put('accentSurface', SFColor.toHex(surface));
        t.put('accentBorder', SFColor.toHex(SFColor.mix(acc, SFColor.WHITE, 0.72)));
        t.put('accentText', SFColor.toHex(SFColor.inkOn(SFColor.shade(acc, 0.45), surface, 4.5)));
        t.put('accentTextDeep', SFColor.toHex(SFColor.inkOn(SFColor.shade(acc, 0.62), surface, 4.5)));
        t.put('warnCtaBg', SFColor.toHex(warnBg));
        t.put('warnCtaInk', SFColor.toHex(SFColor.inkFor(warnBg)));
        t.put('warnCtaShadow', SFColor.toRgba(warnBg, 0.25));
    }

    private static String esc(String s) {
        return String.isBlank(s) ? '' : s.escapeHtml4();
    }

    /** http/https only, and neutralise a quote that could break out of href="". */
    private static String safeUrl(String url) {
        if (String.isBlank(url)) return '#';
        String u = url.trim();
        String low = u.toLowerCase();
        if (!low.startsWith('http://') && !low.startsWith('https://')) return '#';
        return u.replace('"', '%22');
    }

    private static String[] toneQuad(String tone) {
        Map<String, String> t = getEmailTokens();
        String key = (tone == 'danger' || tone == 'success' || tone == 'warning' || tone == 'neutral')
            ? tone : 'neutral';
        if (key == 'warning') {
            return new String[]{ t.get('accentSurface'), t.get('accentBorder'), t.get('accentText'), t.get('warnDot') };
        }
        return new String[]{ t.get(key + 'Surface'), t.get(key + 'Border'), t.get(key + 'Text'), t.get(key + 'Dot') };
    }

    private static final String FF =
        'font-family:-apple-system,BlinkMacSystemFont,\'Segoe UI\',Roboto,Helvetica,Arial,sans-serif;';

    /** escapeHtml4'd company name — the single source for the wordmark and
     *  every "…SignForce…" body literal. */
    public static String brandName() {
        return esc(getEmailTokens().get('companyName'));
    }

    /** Opens the content row between getEmailHeader()'s open table and
     *  getEmailFooter(). Use this instead of a bare <div>. */
    public static String emailBodyOpen() {
        Map<String, String> t = getEmailTokens();
        return '<tr><td class="sf-px sf-py" style="padding:40px 48px;' + FF + 'color:' + t.get('text') + ';">';
    }

    public static String emailBodyClose() {
        return '</td></tr>';
    }

    /** Status pill. tone in {danger,neutral,success,warning}; unknown -> neutral. */
    public static String pill(String tone, String label) {
        String[] q = toneQuad(tone);
        return '<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:0 0 18px;">' +
            '<tr><td bgcolor="' + q[0] + '" style="background-color:' + q[0] + ';border:1px solid ' + q[1] + ';border-radius:20px;padding:5px 12px;' +
            'font-size:11px;font-weight:700;letter-spacing:0.3px;color:' + q[2] + ';line-height:1;">' +
            '<span style="display:inline-block;width:6px;height:6px;border-radius:50%;background:' + q[3] + ';margin-right:6px;vertical-align:middle;"></span>' +
            esc(label) +
            '</td></tr></table>';
    }

    public static String heading(String h1Text) {
        Map<String, String> t = getEmailTokens();
        return '<h1 class="sf-h1" style="margin:0 0 10px;font-size:26px;line-height:34px;font-weight:700;letter-spacing:-0.02em;color:' + t.get('brandPrimary') + ';">' +
            esc(h1Text) + '</h1>';
    }

    /** Sub-paragraph. subHtml is TRUSTED (bodies inject emphasis() here) — do
     *  not pass raw user text; use paragraph() for that. */
    public static String lead(String subHtml) {
        Map<String, String> t = getEmailTokens();
        return '<p style="margin:0 0 22px;font-size:15px;line-height:24px;color:' + t.get('textSub') + ';">' + subHtml + '</p>';
    }

    /** <strong> in the primary text colour, escaped. The only sanctioned way to
     *  bold a value inside lead() — never paste a pre-built <strong> string. */
    public static String emphasis(String textVal) {
        Map<String, String> t = getEmailTokens();
        return '<strong style="color:' + t.get('text') + ';">' + esc(textVal) + '</strong>';
    }

    /** Escaped paragraph — the default-safe choice for any user-derived text. */
    public static String paragraph(String textVal) {
        Map<String, String> t = getEmailTokens();
        return '<p style="margin:0 0 22px;font-size:15px;line-height:24px;color:' + t.get('textSub') + ';">' + esc(textVal) + '</p>';
    }

    public static String footnote(String htmlText) {
        Map<String, String> t = getEmailTokens();
        return '<p style="margin:0;font-size:11px;line-height:18px;color:' + t.get('textMuted') + ';">' + htmlText + '</p>';
    }

    /** Bordered detail card: N uppercase labels over N values in one row with
     *  column dividers. Lists are escaped; a length mismatch renders the shorter
     *  count rather than throwing. */
    public static String metaCard(List<String> labels, List<String> values) {
        Map<String, String> t = getEmailTokens();
        Integer n = Math.min(labels.size(), values.size());
        if (n == 0) return '';
        Integer pct = (Integer) (100 / n);
        String html = '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="margin:0 0 24px;border:1px solid ' + t.get('cardBorder') + ';border-radius:10px;"><tr>';
        for (Integer i = 0; i < n; i++) {
            String divider = (i < n - 1) ? ('border-right:1px solid ' + t.get('cardBorder') + ';') : '';
            html += '<td style="padding:14px 18px;' + divider + 'width:' + pct + '%;">' +
                '<p style="margin:0 0 2px;font-size:10px;font-weight:700;letter-spacing:0.5px;text-transform:uppercase;color:' + t.get('textMuted') + ';">' + esc(labels[i]) + '</p>' +
                '<p style="margin:0;font-size:13px;font-weight:600;color:' + t.get('text') + ';word-break:break-word;">' + esc(values[i]) + '</p>' +
                '</td>';
        }
        return html + '</tr></table>';
    }

    /** Left-accented reason/message card. Both eyebrow and body are escaped —
     *  this closes HTML-injection through comment / decline-reason text. */
    public static String noteCard(String tone, String eyebrow, String bodyText) {
        Map<String, String> t = getEmailTokens();
        String[] q = toneQuad(tone);   // surface, border, text, dot
        return '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="margin:0 0 24px;">' +
            '<tr><td style="border-left:3px solid ' + q[3] + ';background:' + q[0] + ';padding:16px 20px;border-radius:8px;">' +
            '<p style="margin:0 0 6px;font-size:10px;font-weight:700;letter-spacing:0.5px;text-transform:uppercase;color:' + q[2] + ';">' + esc(eyebrow) + '</p>' +
            '<p style="margin:0;font-size:14px;line-height:22px;color:' + t.get('textQuote') + ';white-space:pre-wrap;">' + esc(bodyText) + '</p>' +
            '</td></tr></table>';
    }

    /** Bulletproof CTA button. tone 'brand' (default) or 'warning'. */
    public static String cta(String url, String label, String tone) {
        Map<String, String> t = getEmailTokens();
        String bg     = (tone == 'warning') ? t.get('warnCtaBg')     : t.get('brandFill');
        String ink    = (tone == 'warning') ? t.get('warnCtaInk')    : t.get('brandFillInk');
        String shadow = (tone == 'warning') ? t.get('warnCtaShadow') : t.get('ctaShadow');
        return '<table role="presentation" cellpadding="0" cellspacing="0" border="0" align="left" style="margin:4px 0 24px;">' +
            '<tr><td bgcolor="' + bg + '" style="background-color:' + bg + ';border-radius:9px;box-shadow:0 4px 12px ' + shadow + ';">' +
            '<a href="' + safeUrl(url) + '" class="sf-btn" target="_blank" ' +
            'style="display:inline-block;padding:14px 32px;' + FF + 'font-size:15px;font-weight:600;color:' + ink + ';text-decoration:none;border-radius:9px;letter-spacing:0.1px;">' +
            esc(label) + '</a></td></tr></table>';
    }

    /**
     * The fallback link, presented as a field the reader can select in one go.
     *
     * KNOWN LIMITATION — a "copy to clipboard" button is not possible here, and
     * three variants were built and tested before this was settled:
     *   1. <a href> with onclick  — the handler was stripped, so the click just
     *      opened the link in a new tab.
     *   2. <a> with no href       — inert; nothing happened at all.
     *   3. <button type="button"> — inert; Gmail drops form elements outright.
     * The generated HTML carried a correct onclick in every case (verified by
     * inspecting the emitted markup), so the failure is not in this code. Email
     * clients remove scripts and event handlers as a security measure and expose
     * no clipboard API; there is no flag or markup that changes that. DocuSign and
     * Adobe Sign print a plain URL here for the same reason.
     *
     * What DOES help is making the URL easy to SELECT — its own bordered block,
     * monospace, nothing else on the line — so a triple-click on desktop or a
     * long-press on mobile grabs the whole address and no other text.
     *
     * A working copy button belongs on the signing page, where JavaScript runs.
     */
    public static String fallbackLink(String url) {
        Map<String, String> t = getEmailTokens();
        String safe = safeUrl(url);
        return '<div style="margin:0 0 28px;clear:both;">' +
            '<p style="margin:0 0 6px;' + FF + 'font-size:12px;line-height:18px;color:' + t.get('textHelper') + ';">' +
            'Or copy this link into your browser:</p>' +
            '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="width:100%;">' +
            '<tr><td bgcolor="' + t.get('accentSurface') + '" style="background-color:' + t.get('accentSurface') +
            ';border:1px solid ' + t.get('brandHairline') + ';border-radius:8px;padding:10px 12px;">' +
            '<a href="' + safe + '" style="font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;' +
            'font-size:12px;line-height:18px;color:' + t.get('link') + ';word-break:break-all;text-decoration:none;">' +
            esc(url) + '</a></td></tr></table></div>';
    }

    /** Dotted list rows (e.g. the completion "Signed by" card). dotToken is a
     *  token name such as 'successDot'. Items are escaped. */
    public static String bulletList(String dotToken, List<String> items) {
        Map<String, String> t = getEmailTokens();
        String dot = t.containsKey(dotToken) ? t.get(dotToken) : t.get('successDot');
        String html = '';
        for (String item : items) {
            html += '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="margin:0 0 6px;"><tr>' +
                '<td width="18" valign="middle" style="width:18px;">' +
                '<span style="display:inline-block;width:7px;height:7px;border-radius:50%;background:' + dot + ';"></span></td>' +
                '<td style="' + FF + 'font-size:13px;line-height:20px;color:' + t.get('textQuote') + ';">' + esc(item) + '</td>' +
                '</tr></table>';
        }
        return html;
    }

    /** Panel card with an uppercase eyebrow and trusted inner HTML (e.g. wraps a
     *  bulletList). */
    public static String panelCard(String eyebrow, String innerHtml) {
        Map<String, String> t = getEmailTokens();
        return '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="margin:0 0 24px;">' +
            '<tr><td style="border:1px solid ' + t.get('cardBorder') + ';background:' + t.get('cardFill') + ';padding:18px 20px;border-radius:10px;">' +
            '<p style="margin:0 0 10px;font-size:10px;font-weight:700;letter-spacing:0.5px;text-transform:uppercase;color:' + t.get('textSub') + ';">' + esc(eyebrow) + '</p>' +
            innerHtml +
            '</td></tr></table>';
    }

    /** "What happens next" style strip — N columns of title + body. */
    public static String stepsStrip(String eyebrow, List<String> titles, List<String> bodies) {
        Map<String, String> t = getEmailTokens();
        Integer n = Math.min(titles.size(), bodies.size());
        if (n == 0) return '';
        Integer pct = (Integer) (100 / n);
        String cols = '';
        for (Integer i = 0; i < n; i++) {
            String pad = (i == 0) ? 'padding-right:8px;' : (i == n - 1 ? 'padding-left:8px;' : 'padding:0 8px;');
            cols += '<td valign="top" width="' + pct + '%" style="' + pad + '">' +
                '<p style="margin:0 0 4px;font-size:12px;font-weight:700;color:' + t.get('brandPrimary') + ';">' + esc(titles[i]) + '</p>' +
                '<p style="margin:0;font-size:12px;line-height:18px;color:' + t.get('textHelper') + ';">' + esc(bodies[i]) + '</p>' +
                '</td>';
        }
        return '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="margin:0 0 24px;background:' + t.get('cardFill') + ';border:1px solid ' + t.get('cardBorder') + ';border-radius:10px;">' +
            '<tr><td style="padding:18px 20px;">' +
            '<p style="margin:0 0 12px;font-size:10px;font-weight:700;letter-spacing:0.5px;text-transform:uppercase;color:' + t.get('textSub') + ';">' + esc(eyebrow) + '</p>' +
            '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%"><tr>' + cols + '</tr></table>' +
            '</td></tr></table>';
    }

    /** Monospaced code block — used for the OTP verification code. */
    public static String codeBlock(String code) {
        Map<String, String> t = getEmailTokens();
        return '<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:0 0 24px;">' +
            '<tr><td bgcolor="' + t.get('cardFill') + '" style="background-color:' + t.get('cardFill') + ';border:1px solid ' + t.get('cardBorder') + ';border-radius:10px;padding:16px 28px;' +
            'font-family:\'SFMono-Regular\',Consolas,\'Liberation Mono\',Menlo,monospace;font-size:30px;font-weight:700;letter-spacing:8px;color:' + t.get('text') + ';">' +
            esc(code) + '</td></tr></table>';
    }

    /** First character of the company name for the monogram chip. */
    private static String monogram(String name) {
        if (String.isBlank(name)) return 'S';
        return name.substring(0, 1).toUpperCase();
    }

    /**
     * Modern SaaS email header.
     * Opens HTML doc, body, brand row, and a centered 600px content card.
     */
    public static String getEmailHeader() {
        Map<String, String> t = getEmailTokens();
        String company  = t.get('companyName');
        String logoUrl  = t.get('logoUrl');
        String headerBg = t.get('headerBg');
        String chipInk  = t.get('headerBgText');
        String wordmark = t.get('brandPrimary');
        String accent   = t.get('brandHairline');
        String link     = t.get('link');
        String mono     = monogram(company);

        // Brand block: https logo (if safe) or monogram chip + wordmark.
        String brandBlock;
        if (SFColor.isSafeLogoUrl(logoUrl)) {
            brandBlock =
                '<img src="' + logoUrl.replace('"', '%22') + '" alt="' + esc(company) + '" ' +
                'height="28" style="display:block;max-height:28px;border:0;outline:none;text-decoration:none;"/>';
        } else {
            brandBlock =
                '<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="border-collapse:separate;">' +
                  '<tr>' +
                    '<td valign="middle" align="center" width="28" height="28" bgcolor="' + headerBg + '" ' +
                    'style="width:28px;height:28px;background-color:' + headerBg + ';border-radius:7px;' + FF +
                    'font-size:14px;font-weight:700;color:' + chipInk + ';line-height:28px;text-align:center;letter-spacing:-0.3px;">' +
                      mono +
                    '</td>' +
                    '<td valign="middle" style="padding-left:10px;' + FF +
                    'font-size:15px;font-weight:700;letter-spacing:-0.2px;color:' + wordmark + ';">' +
                      esc(company) +
                    '</td>' +
                  '</tr>' +
                '</table>';
        }

        return
            '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">' +
            '<html xmlns="http://www.w3.org/1999/xhtml">' +
            '<head>' +
            '<meta http-equiv="Content-Type" content="text/html; charset=UTF-8"/>' +
            '<meta name="viewport" content="width=device-width, initial-scale=1.0"/>' +
            '<meta name="x-apple-disable-message-reformatting"/>' +
            '<meta name="color-scheme" content="light only"/>' +
            '<meta name="supported-color-schemes" content="light"/>' +
            '<title>' + esc(company) + '</title>' +
            '<style type="text/css">' +
              '@media only screen and (max-width:620px){' +
                '.sf-container{width:100% !important;max-width:100% !important;}' +
                '.sf-px{padding-left:24px !important;padding-right:24px !important;}' +
                '.sf-py{padding-top:32px !important;padding-bottom:32px !important;}' +
                '.sf-h1{font-size:22px !important;line-height:30px !important;}' +
                '.sf-btn{display:block !important;width:100% !important;box-sizing:border-box !important;}' +
                '.sf-footer-col{display:block !important;width:100% !important;padding:6px 0 !important;text-align:left !important;}' +
              '}' +
              'a{color:' + link + ';text-decoration:none;}' +
              'a:hover{text-decoration:underline;}' +
            '</style>' +
            '</head>' +
            '<body style="margin:0;padding:0;background-color:' + t.get('canvas') + ';-webkit-font-smoothing:antialiased;' +
            '-webkit-text-size-adjust:100%;-ms-text-size-adjust:100%;' + FF + 'color:' + t.get('text') + ';">' +

            '<div style="display:none;max-height:0;overflow:hidden;color:transparent;mso-hide:all;">&zwnj;&zwnj;&zwnj;&zwnj;&zwnj;&zwnj;&zwnj;&zwnj;</div>' +

            '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" ' +
            'style="background-color:' + t.get('canvas') + ';">' +
              '<tr><td align="center" style="padding:32px 12px 16px;">' +

                '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="600" class="sf-container" ' +
                'style="width:600px;max-width:600px;">' +
                  '<tr>' +
                    '<td align="left" style="padding:0 0 18px 4px;">' +
                      brandBlock +
                    '</td>' +
                  '</tr>' +
                '</table>' +

                '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="600" class="sf-container" ' +
                'style="width:600px;max-width:600px;background-color:' + t.get('surface') + ';border:1px solid ' + t.get('shellBorder') + ';border-radius:12px;overflow:hidden;' +
                'box-shadow:0 1px 2px rgba(15,23,42,0.04),0 4px 12px rgba(15,23,42,0.04);">' +

                  '<tr><td style="height:3px;line-height:3px;font-size:0;background-color:' + accent + ';">&nbsp;</td></tr>';
    }

    /**
     * Modern SaaS email footer.
     * Closes the content card and document.
     */
    public static String getEmailFooter() {
        Map<String, String> t = getEmailTokens();
        String footerText = t.get('footerText');
        String company    = t.get('companyName');
        String year       = String.valueOf(Date.today().year());

        return
                  // Sentinel: tools inject extras (e.g. download-links block) just above this row.
                  '<!--SF_BODY_END-->' +

                  '<tr><td class="sf-px" style="background-color:' + t.get('surfaceAlt') + ';padding:22px 48px;border-top:1px solid ' + t.get('cardBorder') + ';">' +
                    '<table role="presentation" cellpadding="0" cellspacing="0" border="0">' +
                      '<tr>' +
                        // Brand chip — deliberately echoes the header monogram so the
                        // email is bookended by the same mark. Follows the brand
                        // primary, so it recolours with the setting like everything else.
                        '<td valign="middle" width="30" style="padding-right:12px;">' +
                          '<table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>' +
                            '<td align="center" valign="middle" width="30" height="30" bgcolor="' + t.get('brandFill') + '" ' +
                            'style="width:30px;height:30px;background-color:' + t.get('brandFill') + ';border-radius:8px;' +
                            'font-family:Arial,Helvetica,sans-serif;font-size:15px;font-weight:700;color:' + t.get('brandFillInk') + ';line-height:30px;text-align:center;">&#10003;</td>' +
                          '</tr></table>' +
                        '</td>' +
                        '<td valign="middle" style="' + FF + '">' +
                          '<p style="margin:0;font-size:12.5px;font-weight:700;letter-spacing:-0.01em;color:' + t.get('text') + ';line-height:17px;">Encrypted and secure</p>' +
                          '<p style="margin:0;font-size:11.5px;color:' + t.get('textSub') + ';line-height:17px;">' +
                            'Sent from <strong style="color:' + t.get('textHelper') + ';font-weight:600;">' + esc(company) + '</strong> — protected in transit and at rest.' +
                          '</p>' +
                        '</td>' +
                      '</tr>' +
                    '</table>' +
                  '</td></tr>' +

                '</table>' +

                '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="600" class="sf-container" ' +
                'style="width:600px;max-width:600px;margin-top:18px;">' +
                  '<tr>' +
                    '<td class="sf-footer-col" align="left" valign="top" width="50%" ' +
                    'style="' + FF + 'font-size:11px;line-height:18px;color:' + t.get('textMuted') + ';padding:0 4px;">' +
                      '<span style="color:' + t.get('textHelper') + ';font-weight:600;">' + esc(company) + '</span><br/>' +
                      esc(footerText) +
                    '</td>' +
                    '<td class="sf-footer-col" align="right" valign="top" width="50%" ' +
                    'style="' + FF + 'font-size:11px;line-height:18px;color:' + t.get('textMuted') + ';padding:0 4px;">' +
                      '&copy; ' + year + ' ' + esc(company) + '<br/>' +
                      'You received this because you are a party to this agreement.' +
                    '</td>' +
                  '</tr>' +
                '</table>' +

                '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="600" class="sf-container" style="width:600px;max-width:600px;">' +
                  '<tr><td style="padding:24px 0;">&nbsp;</td></tr>' +
                '</table>' +

              '</td></tr>' +
            '</table>' +
            '</body></html>';
    }

    /**
     * Get branding data for LWC (signing page branding)
     */
    @AuraEnabled(cacheable=true)
    public static Map<String, String> getBrandingForLWC() {
        return getBrandingMap();
    }
}
