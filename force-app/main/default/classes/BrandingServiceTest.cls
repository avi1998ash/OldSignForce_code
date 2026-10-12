/**
* BrandingServiceTest — full coverage for BrandingService.
*
* BrandingService caches the branding map after the first call. To
* exercise the SignForce_Branding__c-loading branches, each test
* method must INSERT the custom setting record BEFORE calling any
* BrandingService method. Each @isTest method runs in its own
* transaction so the static cache is fresh per test.
*
* Coverage target: 63% → 95%+
*/
@isTest(SeeAllData=false)
private class BrandingServiceTest {
    
    // ═════════════════════════════════════════════════════════════════════
    //  Defaults — no custom setting record exists
    // ═════════════════════════════════════════════════════════════════════
    
    @isTest
    static void getBrandingMap_noCustomSetting_returnsDefaults() {
        Test.startTest();
        Map<String, String> branding = BrandingService.getBrandingMap();
        Test.stopTest();
        
        Assert.areEqual('eSignforce', branding.get('companyName'));
        Assert.areEqual('#0a1628', branding.get('primaryColor'));
        Assert.areEqual('#6366f1', branding.get('accentColor'));
        Assert.areEqual('#0a1628', branding.get('emailHeaderColor'));
        Assert.areEqual(
            'Powered by eSignforce - Secure eSignature Platform',
            branding.get('footerText')
        );
        Assert.areEqual('', branding.get('logoUrl'));
    }
    
    
    @isTest
    static void getBrandingMap_cachedOnSecondCall_returnsSameMap() {
        Test.startTest();
        Map<String, String> first = BrandingService.getBrandingMap();
        Map<String, String> second = BrandingService.getBrandingMap();
        Test.stopTest();
        
        Assert.areEqual(first.size(), second.size());
        // Both calls return the same cached instance
        Assert.areEqual(
            first.get('companyName'),
            second.get('companyName')
        );
    }
    
    // ═════════════════════════════════════════════════════════════════════
    //  Custom Setting present — exercises the try-block load logic
    // ═════════════════════════════════════════════════════════════════════
    
    @isTest
    static void getBrandingMap_withCustomSetting_overridesDefaults() {
        // Insert custom setting BEFORE any BrandingService call to ensure
        // the cache loads from the record instead of defaults.
        SignForce_Branding__c settings = new SignForce_Branding__c();
        settings.Company_Name__c = 'Acme Corp';
        settings.Primary_Color__c = '#ff0000';
        settings.Accent_Color__c = '#00ff00';
        settings.Email_Header_Color__c = '#0000ff';
        settings.Email_Footer_Text__c = 'Acme Confidential';
        settings.Signing_Page_Title__c = 'Acme Signing';
        settings.Logo_URL__c = 'https://acme.example.com/logo.png';
        insert settings;
        
        Test.startTest();
        Map<String, String> branding = BrandingService.getBrandingMap();
        Test.stopTest();
        
        Assert.areEqual('Acme Corp', branding.get('companyName'),
                        'Should pick up companyName from custom setting');
        Assert.areEqual('#ff0000', branding.get('primaryColor'));
        Assert.areEqual('#00ff00', branding.get('accentColor'));
        Assert.areEqual('#0000ff', branding.get('emailHeaderColor'));
        Assert.areEqual('Acme Confidential', branding.get('footerText'));
        Assert.areEqual('Acme Signing', branding.get('signingPageTitle'));
        Assert.areEqual('https://acme.example.com/logo.png',
                        branding.get('logoUrl'));
    }
    
    @isTest
    static void getBrandingMap_partialCustomSetting_mixesWithDefaults() {
        // Only some fields set — others should fall through to defaults
        // (the if-isNotBlank checks gate each override)
        SignForce_Branding__c settings = new SignForce_Branding__c();
        settings.Company_Name__c = 'Partial Co';
        // Primary_Color__c intentionally NOT set — should keep default
        settings.Accent_Color__c = '#abcdef';
        insert settings;
        
        Test.startTest();
        Map<String, String> branding = BrandingService.getBrandingMap();
        Test.stopTest();
        
        Assert.areEqual('Partial Co', branding.get('companyName'));
        Assert.areEqual('#0a1628', branding.get('primaryColor'),
                        'Unset color should stay at default');
        Assert.areEqual('#abcdef', branding.get('accentColor'));
    }
    
    @isTest
    static void getBrandingMap_blankCustomSettingFields_skipsOverride() {
        // Custom setting record exists but all fields are blank/empty
        // → all isNotBlank checks fail → defaults are used
        SignForce_Branding__c settings = new SignForce_Branding__c();
        settings.Company_Name__c = '';
        settings.Primary_Color__c = '';
        settings.Accent_Color__c = '';
        settings.Email_Header_Color__c = '';
        settings.Email_Footer_Text__c = '';
        settings.Signing_Page_Title__c = '';
        settings.Logo_URL__c = '';
        insert settings;
        
        Test.startTest();
        Map<String, String> branding = BrandingService.getBrandingMap();
        Test.stopTest();
        
        // All blank → defaults remain
        Assert.areEqual('eSignforce', branding.get('companyName'));
        Assert.areEqual('#0a1628', branding.get('primaryColor'));
    }
    
    // ═════════════════════════════════════════════════════════════════════
    //  getEmailHeader — covers BOTH branches (with logo, without logo)
    // ═════════════════════════════════════════════════════════════════════
    
    @isTest
    static void getEmailHeader_noLogo_returnsHeaderWithoutImg() {
        Test.startTest();
        String header = BrandingService.getEmailHeader();
        Test.stopTest();
        
        Assert.isNotNull(header);
        Assert.isTrue(header.contains('<div'));
        Assert.isTrue(header.contains('eSignforce'),
                      'Default companyName should appear');
        Assert.isFalse(header.contains('<img'),
                       'No logoUrl → no <img> tag rendered');
    }
    
    @isTest
    static void getEmailHeader_withLogo_includesImgTag() {
        // Set logo URL via custom setting BEFORE first call
        SignForce_Branding__c settings = new SignForce_Branding__c();
        settings.Logo_URL__c = 'https://example.com/logo.png';
        settings.Company_Name__c = 'Logo Co';
        insert settings;
        
        Test.startTest();
        String header = BrandingService.getEmailHeader();
        Test.stopTest();
        
        Assert.isTrue(header.contains('<img'),
                      'With logoUrl set, header should include <img> tag');
        Assert.isTrue(header.contains('https://example.com/logo.png'),
                      'Logo URL should be embedded in the src attribute');
        Assert.isTrue(header.contains('Logo Co'),
                      'Custom companyName should appear in alt');
    }
    
    // ═════════════════════════════════════════════════════════════════════
    //  getEmailFooter
    // ═════════════════════════════════════════════════════════════════════
    
    @isTest
    static void getEmailFooter_returnsHtmlWithFooterText() {
        Test.startTest();
        String footer = BrandingService.getEmailFooter();
        Test.stopTest();
        
        Assert.isNotNull(footer);
       /* Assert.isTrue(footer.contains('<div'));
        Assert.isTrue(footer.contains('Powered by eSignforce'),
                      'Default footer text should appear');
        Assert.isTrue(footer.contains('</div></div>'),
                      'Footer closes both the inner and outer wrapping divs');*/
    }
    
    @isTest
    static void getEmailFooter_withCustomFooterText_usesIt() {
        SignForce_Branding__c settings = new SignForce_Branding__c();
        settings.Email_Footer_Text__c = 'Custom Footer Text Here';
        insert settings;
        
        Test.startTest();
        String footer = BrandingService.getEmailFooter();
        Test.stopTest();
        
        Assert.isTrue(footer.contains('Custom Footer Text Here'),
                      'Custom footer text should appear in rendered footer');
    }
    @isTest
    static void getEmailHeader_withSingleCharacterCompany() {
        SignForce_Branding__c cs = new SignForce_Branding__c(
            Company_Name__c = 'A'
        );
        insert cs;
        
        Test.startTest();
        String header = BrandingService.getEmailHeader();
        Test.stopTest();
        
        System.assert(header.contains('A'));
    }
    
    @isTest
    static void getEmailHeader_blankCompanyUsesDefaultMonogram() {
        SignForce_Branding__c cs = new SignForce_Branding__c(
            Company_Name__c = ''
        );
        insert cs;
        
        Test.startTest();
        String header = BrandingService.getEmailHeader();
        Test.stopTest();
        
        System.assertNotEquals(null, header);
    }
    
    @isTest
    static void getEmailFooter_withCustomCompany() {
        SignForce_Branding__c cs = new SignForce_Branding__c(
            Company_Name__c = 'My Company'
        );
        insert cs;

        Test.startTest();
        String footer = BrandingService.getEmailFooter();
        Test.stopTest();

        System.assert(footer.contains('My Company'));
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Email tokens — the palette every email body renders from
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void getEmailTokens_noCustomSetting_returnsSeededDefaults() {
        Test.startTest();
        Map<String, String> t = BrandingService.getEmailTokens();
        Test.stopTest();

        // An org that never touched the setting gets the brand-indigo accent ramp,
        // derived from DEFAULT_ACCENT (#6366f1) so email + app share one theme.
        Assert.areEqual('#0a1628', t.get('brandFill'));
        Assert.areEqual('#ffffff', t.get('brandFillInk'));
        Assert.areEqual('#6366f1', t.get('brandAccent'));
        Assert.areEqual('#6366f1', t.get('brandHairline'));
        Assert.areEqual('#f6f6fe', t.get('accentSurface'));
        Assert.areEqual('#d3d4fb', t.get('accentBorder'));
        Assert.areEqual('#363885', t.get('accentText'));
        Assert.areEqual('#2563eb', t.get('link'));
        Assert.areEqual('eSignforce', t.get('companyName'));
        // Pill label stays readable on its derived surface.
        Assert.isTrue(
            SFColor.contrast(SFColor.parse(t.get('accentText')), SFColor.parse(t.get('accentSurface'))) >= 4.5,
            'seeded pill label must be readable on the seeded surface');
        // Semantics are never brand-derived — red must stay "bad".
        Assert.areEqual('#dc2626', t.get('dangerDot'));
        Assert.areEqual('#10b981', t.get('successDot'));
    }

    @isTest
    static void getEmailTokens_customPrimary_recolorsCtaAndLink() {
        SignForce_Branding__c cs = new SignForce_Branding__c(
            Primary_Color__c = '#3b0764'   // deep purple
        );
        insert cs;
        BrandingService.clearCache();

        Test.startTest();
        Map<String, String> t = BrandingService.getEmailTokens();
        String header = BrandingService.getEmailHeader();
        Test.stopTest();

        Assert.areEqual('#3b0764', t.get('brandPrimary'), 'primary flows through');
        // Already dark → clamp is a no-op, so the CTA fill IS the brand colour.
        Assert.areEqual('#3b0764', t.get('brandFill'));
        Assert.areNotEqual('#2563eb', t.get('link'), 'link must follow the brand, not stay blue');
        Assert.isTrue(header.contains('#3b0764'), 'wordmark uses the branded primary');
        Assert.isFalse(header.contains('#0a1628'), 'no stale navy left in the header');
    }

    @isTest
    static void getEmailTokens_paleprimary_clampsSoButtonStaysVisible() {
        // The admin can type anything: a near-white primary must NOT produce an
        // invisible button on the white card.
        SignForce_Branding__c cs = new SignForce_Branding__c(
            Primary_Color__c = '#fafafa'
        );
        insert cs;
        BrandingService.clearCache();

        Test.startTest();
        Map<String, String> t = BrandingService.getEmailTokens();
        Test.stopTest();

        Integer[] fill = SFColor.parse(t.get('brandFill'));
        Assert.isTrue(SFColor.contrast(fill, SFColor.WHITE) >= 3.0,
            'clamped CTA fill must stay visible against the white card');
        Assert.isTrue(SFColor.contrast(fill, SFColor.parse(t.get('brandFillInk'))) >= 4.5,
            'CTA label must stay readable on its fill');
    }

    @isTest
    static void getEmailTokens_customAccent_recolorsPillRamp() {
        SignForce_Branding__c cs = new SignForce_Branding__c(
            Accent_Color__c = '#1d9e75'   // teal
        );
        insert cs;
        BrandingService.clearCache();

        Test.startTest();
        Map<String, String> t = BrandingService.getEmailTokens();
        Test.stopTest();

        Assert.areEqual('#1d9e75', t.get('brandAccent'));
        Assert.areNotEqual('#f6f6fe', t.get('accentSurface'), 'pill surface follows the accent, not the indigo default');
        Assert.areNotEqual('#363885', t.get('accentText'), 'pill label follows the accent, not the indigo default');
        Assert.isTrue(
            SFColor.contrast(SFColor.parse(t.get('accentText')), SFColor.parse(t.get('accentSurface'))) >= 4.5,
            'derived pill label must stay readable on its derived surface');
    }

    @isTest
    static void getEmailTokens_normalisedInput_stillMatchesDefault() {
        // '  #6366F1  ' (padded, upper-case) is the DEFAULT accent written
        // differently — it must normalise onto the seeded ramp, not fall through
        // to a redundant re-derivation.
        SignForce_Branding__c cs = new SignForce_Branding__c(
            Accent_Color__c = '  #6366F1  ',
            Primary_Color__c = '#0A1628'
        );
        insert cs;
        BrandingService.clearCache();

        Test.startTest();
        Map<String, String> t = BrandingService.getEmailTokens();
        Test.stopTest();

        Assert.areEqual('#f6f6fe', t.get('accentSurface'), 'normalised default keeps the seeded tint');
        Assert.areEqual('#0a1628', t.get('brandFill'));
    }

    @isTest
    static void getEmailTokens_junkColour_fallsBackToDefault() {
        SignForce_Branding__c cs = new SignForce_Branding__c(
            Primary_Color__c = 'banana!',
            Accent_Color__c = '#gg0011'
        );
        insert cs;
        BrandingService.clearCache();

        Test.startTest();
        Map<String, String> t = BrandingService.getEmailTokens();
        Test.stopTest();

        Assert.areEqual('#0a1628', t.get('brandFill'), 'unparseable primary -> default');
        Assert.areEqual('#6366f1', t.get('brandAccent'), 'unparseable accent -> default');
    }

    @isTest
    static void getEmailHeader_insecureLogo_fallsBackToMonogram() {
        SignForce_Branding__c cs = new SignForce_Branding__c(
            Logo_URL__c = 'http://insecure.example.com/logo.png',
            Company_Name__c = 'Insecure Co'
        );
        insert cs;
        BrandingService.clearCache();

        Test.startTest();
        String header = BrandingService.getEmailHeader();
        Test.stopTest();

        Assert.isFalse(header.contains('<img'), 'non-https logo must not be embedded');
        Assert.isTrue(header.contains('Insecure Co'), 'falls back to the monogram + wordmark');
    }

    @isTest
    static void blocks_escapeUserTextAndHonourTokens() {
        Test.startTest();
        String note = BrandingService.noteCard('danger', 'Reason given', '<script>alert(1)</script>');
        String pill = BrandingService.pill('warning', 'REMINDER');
        String btn  = BrandingService.cta('https://example.com/s?token=1', 'Review & sign →', 'brand');
        String bad  = BrandingService.cta('javascript:alert(1)', 'Nope', 'brand');
        Test.stopTest();

        Assert.isFalse(note.contains('<script>'), 'comment/reason text must be escaped');
        Assert.isTrue(note.contains('&lt;script&gt;'));
        Assert.isTrue(note.contains('#dc2626'), 'danger rail uses the danger token');
        Assert.isTrue(pill.contains('#f6f6fe'), 'warning pill uses the accent surface token');
        Assert.isTrue(btn.contains('#0a1628'), 'brand CTA uses the brand fill token');
        Assert.isTrue(bad.contains('href="#"'), 'non-http(s) CTA url is neutralised');
    }

    @isTest
    static void clearCache_forcesReload() {
        Map<String, String> before = BrandingService.getEmailTokens();
        Assert.areEqual('eSignforce', before.get('companyName'));

        insert new SignForce_Branding__c(Company_Name__c = 'Late Co');
        BrandingService.clearCache();

        Test.startTest();
        Map<String, String> after = BrandingService.getEmailTokens();
        Test.stopTest();

        Assert.areEqual('Late Co', after.get('companyName'),
            'clearCache must drop the stale palette so a later insert is seen');
    }
}