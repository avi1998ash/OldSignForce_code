/**
 * PDFPreviewControllerTest — coverage for PDFPreviewController.
 *
 * Target: 44% → 80%+
 *
 * Note: The large-file branches (size > 4.5MB) of getPDFInfo and the
 * multi-chunk path of getPDFChunk are NOT tested here because creating a
 * 4.5MB+ Blob in test context exceeds the 6MB Apex heap limit (the blob
 * gets duplicated when base64-encoded internally, hitting ~12MB total).
 *
 * We achieve coverage on the other methods including the full
 * getOrCreateDistributionUrl helper via createDistributionUrl tests.
 */
@isTest(SeeAllData=false)
private class PDFPreviewControllerTest {

    // ═════════════════════════════════════════════════════════════════════
    //  Helpers
    // ═════════════════════════════════════════════════════════════════════

    private static ContentVersion createCv(String title, Blob data) {
        ContentVersion cv = new ContentVersion();
        cv.Title = title;
        cv.PathOnClient = title + '.pdf';
        cv.VersionData = data;
        cv.IsMajorVersion = true;
        insert cv;
        return [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id];
    }

    private static ContentDistribution createCd(Id cvId) {
        ContentDistribution cd = new ContentDistribution();
        cd.Name = 'PDFPreview-' + cvId;
        cd.ContentVersionId = cvId;
        cd.PreferencesAllowViewInBrowser = true;
        cd.PreferencesLinkLatestVersion = false;
        cd.PreferencesNotifyOnVisit = false;
        cd.PreferencesPasswordRequired = false;
        cd.PreferencesAllowOriginalDownload = true;
        Database.insert(cd, true, AccessLevel.USER_MODE);
        return cd;
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Constructor — 3 branches
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void constructor_withCvIdParam_setsCvId() {
        PageReference page = Page.PDFPreview;
        page.getParameters().put('cvId', '068000000000000AAA');
        Test.setCurrentPage(page);

        Test.startTest();
        PDFPreviewController ctrl = new PDFPreviewController();
        Test.stopTest();

        Assert.areEqual('068000000000000AAA', ctrl.cvId);
        Assert.areEqual(false, ctrl.usePublicUrl);
        Assert.areEqual('', ctrl.directDownloadUrl);
    }

    @isTest
    static void constructor_withPdfUrl_setsUsePublicUrlTrue() {
        PageReference page = Page.PDFPreview;
        page.getParameters().put('pdfUrl', 'https://example.com/x.pdf');
        Test.setCurrentPage(page);

        Test.startTest();
        PDFPreviewController ctrl = new PDFPreviewController();
        Test.stopTest();

        Assert.areEqual('https://example.com/x.pdf', ctrl.pdfUrl);
        Assert.areEqual(true, ctrl.usePublicUrl);
    }

    @isTest
    static void constructor_noParams_defaultsAllNull() {
        PageReference page = Page.PDFPreview;
        Test.setCurrentPage(page);

        Test.startTest();
        PDFPreviewController ctrl = new PDFPreviewController();
        Test.stopTest();

        Assert.areEqual(null, ctrl.cvId);
        Assert.areEqual(null, ctrl.pdfUrl);
        Assert.areEqual(false, ctrl.usePublicUrl);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  getPDFBase64
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void getPDFBase64_returnsBase64() {
        ContentVersion cv = createCv('Base64 CV', Blob.valueOf('test pdf bytes'));

        Test.startTest();
        String b64 = PDFPreviewController.getPDFBase64(cv.Id);
        Test.stopTest();

        Assert.isNotNull(b64);
        String decoded = EncodingUtil.base64Decode(b64).toString();
        Assert.areEqual('test pdf bytes', decoded);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  getDistributionUrl
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void getDistributionUrl_withExistingCd_returnsUrl() {
        ContentVersion cv = createCv('CD CV', Blob.valueOf('cd bytes'));
        createCd(cv.Id);

        Test.startTest();
        String url = PDFPreviewController.getDistributionUrl(cv.Id);
        Test.stopTest();

        Assert.isNotNull(url);
    }

    @isTest
    static void getDistributionUrl_noCd_returnsNull() {
        ContentVersion cv = createCv('NoCD CV', Blob.valueOf('no cd'));

        Test.startTest();
        String url = PDFPreviewController.getDistributionUrl(cv.Id);
        Test.stopTest();

        Assert.areEqual(null, url, 'No ContentDistribution → null URL');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  getPDFInfo — small-file branch only (large-file path skipped for heap)
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void getPDFInfo_smallFile_returnsSizeAndChunkInfo() {
        ContentVersion cv = createCv('Info Small', Blob.valueOf('small pdf content'));

        Test.startTest();
        Map<String, Object> info = PDFPreviewController.getPDFInfo(cv.Id);
        Test.stopTest();

        Assert.isNotNull(info);
        Assert.isTrue(info.containsKey('size'));
        Assert.isTrue(info.containsKey('fileType'));
        Assert.isTrue(info.containsKey('totalChunks'));
        Assert.isTrue(info.containsKey('chunkSize'));
        Assert.areEqual(3000000, info.get('chunkSize'));
        Assert.isFalse(info.containsKey('distributionUrl'),
            'Small file should NOT trigger ContentDistribution');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  createDistributionUrl — both branches of getOrCreateDistributionUrl
    //
    //  This exercises the SAME helper that the large-file path would use,
    //  so we still get coverage on it without needing a 5MB blob.
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void createDistributionUrl_freshCreate_returnsUrl() {
        ContentVersion cv = createCv('Dist Fresh', Blob.valueOf('fresh bytes'));

        Test.startTest();
        PDFPreviewController.createDistributionUrl(cv.Id);
        Test.stopTest();

        Integer cdCount = [
            SELECT COUNT() FROM ContentDistribution WHERE ContentVersionId = :cv.Id
        ];
        Assert.areEqual(1, cdCount, 'One ContentDistribution should be created');
    }

    @isTest
    static void createDistributionUrl_existingCd_reusesExisting() {
        ContentVersion cv = createCv('Dist Existing', Blob.valueOf('existing bytes'));
        createCd(cv.Id);

        Test.startTest();
        PDFPreviewController.createDistributionUrl(cv.Id);
        Test.stopTest();

        Integer cdCount = [
            SELECT COUNT() FROM ContentDistribution WHERE ContentVersionId = :cv.Id
        ];
        Assert.areEqual(1, cdCount,
            'Existing ContentDistribution should be reused, not duplicated');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  getPDFChunk — small file branches only
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void getPDFChunk_firstChunk_returnsData() {
        ContentVersion cv = createCv('Chunk First', Blob.valueOf('chunk one bytes'));

        Test.startTest();
        String chunk = PDFPreviewController.getPDFChunk(cv.Id, 0);
        Test.stopTest();

        Assert.isNotNull(chunk);
        Assert.isTrue(chunk.length() > 0);
    }

    @isTest
    static void getPDFChunk_pastEnd_returnsEmpty() {
        ContentVersion cv = createCv('Chunk PastEnd', Blob.valueOf('small'));

        Test.startTest();
        String chunk = PDFPreviewController.getPDFChunk(cv.Id, 100);
        Test.stopTest();

        Assert.areEqual('', chunk,
            'Chunk index past file end should return empty string');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Guest branch — a Site Guest User is routed to GuestSigningApi
    //  (the tests above run as an internal user, i.e. GuestSigningApiInternal)
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void guestBranch_routesToGuestSigningApi() {
        ContentVersion cv = createCv('Guest Branch', Blob.valueOf('guest pdf'));
        PDFPreviewController.forceGuestForTest = true;
        Test.startTest();
        String b64 = PDFPreviewController.getPDFBase64(cv.Id);
        Map<String, Object> info = PDFPreviewController.getPDFInfo(cv.Id);
        String chunk = PDFPreviewController.getPDFChunk(cv.Id, 0);
        String dist = PDFPreviewController.getDistributionUrl(cv.Id);
        String created = PDFPreviewController.createDistributionUrl(cv.Id);
        Test.stopTest();
        PDFPreviewController.forceGuestForTest = null;
        Assert.areEqual(EncodingUtil.base64Encode(Blob.valueOf('guest pdf')), b64);
        Assert.areEqual(1, info.get('totalChunks'));
        Assert.areEqual(b64, chunk);
        Assert.areEqual(null, dist);
        Assert.isTrue(String.isNotBlank(created));
    }

    @isTest
    static void internalUser_isNotRoutedToGuestApi() {
        Assert.areEqual(null, PDFPreviewController.forceGuestForTest);
        ContentVersion cv = createCv('Internal Branch', Blob.valueOf('internal pdf'));
        PDFPreviewController.forceGuestForTest = false;
        Assert.areEqual(EncodingUtil.base64Encode(Blob.valueOf('internal pdf')), PDFPreviewController.getPDFBase64(cv.Id));
        PDFPreviewController.forceGuestForTest = null;
    }
}
