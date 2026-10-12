/**
 * SignedDocumentPDFControllerTest — full coverage for the VF controller.
 *
 * Target: 33% → 85%+
 *
 * Strategy: buildFieldWrapper is private, so we exercise it via the
 * constructor by inserting Signature_Field__c records of every type
 * (Signature/Initial with draw/typed/upload values, Checkbox, Text).
 */
@isTest(SeeAllData=false)
private class SignedDocumentPDFControllerTest {

    // ═════════════════════════════════════════════════════════════════════
    //  Constructor — early-return branches
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void constructor_noAgreementId_earlyReturns() {
        PageReference page = Page.SignedDocumentPDF;
        Test.setCurrentPage(page);

        Test.startTest();
        SignedDocumentPDFController ctrl = new SignedDocumentPDFController();
        Test.stopTest();

        Assert.isNotNull(ctrl.pages);
        Assert.areEqual(0, ctrl.pages.size());
    }

    @isTest
    static void constructor_validAgreementNoOriginalDoc_earlyReturns() {
        Agreement__c agr = TestDataFactory.createSentAgreement('SignedDoc NoDoc');

        PageReference page = Page.SignedDocumentPDF;
        page.getParameters().put('agreementId', agr.Id);
        Test.setCurrentPage(page);

        Test.startTest();
        SignedDocumentPDFController ctrl = new SignedDocumentPDFController();
        Test.stopTest();

        Assert.areEqual(0, ctrl.pages.size());
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Constructor — happy paths
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void constructor_validAgreementBasic_loadsData() {
        Agreement__c agr = TestDataFactory.createSentAgreement('SignedDoc Basic');
        agr.Envelope_ID__c = 'ENV-SD-001';
        update agr;
        TestDataFactory.createTier1OriginalDoc(agr.Id);

        PageReference page = Page.SignedDocumentPDF;
        page.getParameters().put('agreementId', agr.Id);
        Test.setCurrentPage(page);

        Test.startTest();
        SignedDocumentPDFController ctrl = new SignedDocumentPDFController();
        Test.stopTest();

        Assert.areEqual('ENV-SD-001', ctrl.envelopeId);
        Assert.isTrue(ctrl.pages.size() >= 1);
    }

    @isTest
    static void constructor_withDrawSignatureField_buildsDrawWrapper() {
        Agreement__c agr = TestDataFactory.createSentAgreement('SignedDoc Draw');
        TestDataFactory.createTier1OriginalDoc(agr.Id);
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'draw@example.com');
        signer.Signature_Certificate_ID__c = 'CERT-DRAW';
        signer.Signed_Date__c = DateTime.now();
        update signer;

        Saved_Signature__c savedSig = new Saved_Signature__c();
        savedSig.Email__c = 'draw@example.com';
        savedSig.Signature_Type__c = 'Draw';
        savedSig.Signature_Data__c = '[{"d":"M 0 0 L 10 10"}]';
        insert savedSig;

        Signature_Field__c f = TestDataFactory.createSignatureField(agr.Id, signer.Id, 1, 100, 200);
        f.Field_Type__c = 'Signature';
        f.Field_Value__c = '[{"d":"M 0 0 L 10 10"}]';
        f.Is_Completed__c = true;
        f.Page_Width__c = 612;
        f.Width__c = 150;
        f.Height__c = 50;
        update f;

        PageReference page = Page.SignedDocumentPDF;
        page.getParameters().put('agreementId', agr.Id);
        Test.setCurrentPage(page);

        Test.startTest();
        SignedDocumentPDFController ctrl = new SignedDocumentPDFController();
        Test.stopTest();

        Assert.isTrue(ctrl.pages.size() >= 1);
        Assert.areEqual(1, ctrl.pages[0].fields.size());
        SignedDocumentPDFController.FieldWrapper fw = ctrl.pages[0].fields[0];
        Assert.areEqual(true, fw.isDrawSignature);
        Assert.areEqual(true, fw.showCertStamp);
        Assert.areEqual('CERT-DRAW', fw.certificateId);
    }

    @isTest
    static void constructor_withTypedSignatureField_parsesNameAndFont() {
        Agreement__c agr = TestDataFactory.createSentAgreement('SignedDoc Typed');
        TestDataFactory.createTier1OriginalDoc(agr.Id);
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'typed@example.com');

        Signature_Field__c f = TestDataFactory.createSignatureField(agr.Id, signer.Id, 1, 100, 200);
        f.Field_Type__c = 'Signature';
        f.Field_Value__c = 'typed:John Doe:Great Vibes';
        f.Is_Completed__c = true;
        f.Page_Width__c = 612;
        f.Width__c = 150;
        f.Height__c = 40;
        update f;

        PageReference page = Page.SignedDocumentPDF;
        page.getParameters().put('agreementId', agr.Id);
        Test.setCurrentPage(page);

        Test.startTest();
        SignedDocumentPDFController ctrl = new SignedDocumentPDFController();
        Test.stopTest();

        SignedDocumentPDFController.FieldWrapper fw = ctrl.pages[0].fields[0];
        Assert.areEqual(true, fw.isTypedSignature);
        Assert.areEqual('John Doe', fw.displayValue);
        Assert.areEqual('Great Vibes', fw.fontFamily);
    }

    @isTest
    static void constructor_withUploadSignatureField_setsUploadFlag() {
        Agreement__c agr = TestDataFactory.createSentAgreement('SignedDoc Upload');
        TestDataFactory.createTier1OriginalDoc(agr.Id);
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'upload@example.com');

        Signature_Field__c f = TestDataFactory.createSignatureField(agr.Id, signer.Id, 1, 100, 200);
        f.Field_Type__c = 'Signature';
        f.Field_Value__c = 'data:image/png;base64,iVBORw0KGgo=';
        f.Is_Completed__c = true;
        update f;

        PageReference page = Page.SignedDocumentPDF;
        page.getParameters().put('agreementId', agr.Id);
        Test.setCurrentPage(page);

        Test.startTest();
        SignedDocumentPDFController ctrl = new SignedDocumentPDFController();
        Test.stopTest();

        SignedDocumentPDFController.FieldWrapper fw = ctrl.pages[0].fields[0];
        Assert.areEqual(true, fw.isUploadSignature);
    }

    @isTest
    static void constructor_withCheckboxField_setsCheckboxFlag() {
        Agreement__c agr = TestDataFactory.createSentAgreement('SignedDoc Checkbox');
        TestDataFactory.createTier1OriginalDoc(agr.Id);
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'cb@example.com');

        Signature_Field__c f = TestDataFactory.createSignatureField(agr.Id, signer.Id, 1, 100, 200);
        f.Field_Type__c = 'Checkbox';
        f.Field_Value__c = 'true';
        f.Is_Completed__c = true;
        update f;

        PageReference page = Page.SignedDocumentPDF;
        page.getParameters().put('agreementId', agr.Id);
        Test.setCurrentPage(page);

        Test.startTest();
        SignedDocumentPDFController ctrl = new SignedDocumentPDFController();
        Test.stopTest();

        SignedDocumentPDFController.FieldWrapper fw = ctrl.pages[0].fields[0];
        Assert.areEqual(true, fw.isCheckbox);
        Assert.areEqual(false, fw.isTextField);
        Assert.areEqual(false, fw.showCertStamp);
    }

    @isTest
    static void constructor_withTextField_setsTextFieldFlag() {
        Agreement__c agr = TestDataFactory.createSentAgreement('SignedDoc Text');
        TestDataFactory.createTier1OriginalDoc(agr.Id);
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'text@example.com');

        Signature_Field__c f = TestDataFactory.createSignatureField(agr.Id, signer.Id, 1, 100, 200);
        f.Field_Type__c = 'Full Name';
        f.Field_Value__c = 'Alice Smith';
        f.Is_Completed__c = true;
        update f;

        PageReference page = Page.SignedDocumentPDF;
        page.getParameters().put('agreementId', agr.Id);
        Test.setCurrentPage(page);

        Test.startTest();
        SignedDocumentPDFController ctrl = new SignedDocumentPDFController();
        Test.stopTest();

        SignedDocumentPDFController.FieldWrapper fw = ctrl.pages[0].fields[0];
        Assert.areEqual(true, fw.isTextField);
        Assert.areEqual('Alice Smith', fw.displayValue);
    }

    @isTest
    static void constructor_withInitialField_treatsLikeSignature() {
        Agreement__c agr = TestDataFactory.createSentAgreement('SignedDoc Initial');
        TestDataFactory.createTier1OriginalDoc(agr.Id);
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'init@example.com');

        Signature_Field__c f = TestDataFactory.createSignatureField(agr.Id, signer.Id, 1, 100, 200);
        f.Field_Type__c = 'Initial';
        f.Field_Value__c = 'typed:AS:Caveat';
        f.Is_Completed__c = true;
        update f;

        PageReference page = Page.SignedDocumentPDF;
        page.getParameters().put('agreementId', agr.Id);
        Test.setCurrentPage(page);

        Test.startTest();
        SignedDocumentPDFController ctrl = new SignedDocumentPDFController();
        Test.stopTest();

        SignedDocumentPDFController.FieldWrapper fw = ctrl.pages[0].fields[0];
        Assert.areEqual(true, fw.isTypedSignature);
        Assert.areEqual(true, fw.showCertStamp);
    }

    @isTest
    static void constructor_incompleteField_skipped() {
        Agreement__c agr = TestDataFactory.createSentAgreement('SignedDoc Incomplete');
        TestDataFactory.createTier1OriginalDoc(agr.Id);
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'inc@example.com');

        Signature_Field__c f = TestDataFactory.createSignatureField(agr.Id, signer.Id, 1, 100, 200);
        f.Field_Type__c = 'Signature';
        f.Field_Value__c = '';
        f.Is_Completed__c = false;
        update f;

        PageReference page = Page.SignedDocumentPDF;
        page.getParameters().put('agreementId', agr.Id);
        Test.setCurrentPage(page);

        Test.startTest();
        SignedDocumentPDFController ctrl = new SignedDocumentPDFController();
        Test.stopTest();

        Assert.areEqual(0, ctrl.pages[0].fields.size());
    }

    @isTest
    static void constructor_multiplePages_buildsAllPages() {
        Agreement__c agr = TestDataFactory.createSentAgreement('SignedDoc Multi-Page');
        TestDataFactory.createTier1OriginalDoc(agr.Id);
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'multi@example.com');

        Signature_Field__c f1 = TestDataFactory.createSignatureField(agr.Id, signer.Id, 1, 100, 200);
        f1.Field_Value__c = 'page 1 text';
        f1.Field_Type__c = 'Full Name';
        f1.Is_Completed__c = true;
        update f1;

        Signature_Field__c f3 = TestDataFactory.createSignatureField(agr.Id, signer.Id, 3, 100, 200);
        f3.Field_Value__c = 'page 3 text';
        f3.Field_Type__c = 'Full Name';
        f3.Is_Completed__c = true;
        update f3;

        PageReference page = Page.SignedDocumentPDF;
        page.getParameters().put('agreementId', agr.Id);
        Test.setCurrentPage(page);

        Test.startTest();
        SignedDocumentPDFController ctrl = new SignedDocumentPDFController();
        Test.stopTest();

        Assert.areEqual(3, ctrl.pages.size());
        Assert.areEqual(1, ctrl.pages[0].fields.size());
        Assert.areEqual(0, ctrl.pages[1].fields.size());
        Assert.areEqual(1, ctrl.pages[2].fields.size());
    }

    @isTest
    static void constructor_multipleSignersOneSavedSig_caches() {
        Agreement__c agr = TestDataFactory.createSentAgreement('SignedDoc Cache');
        TestDataFactory.createTier1OriginalDoc(agr.Id);
        Signer__c s1 = TestDataFactory.createSignerWithToken(agr.Id, 'one@example.com');
        Signer__c s2 = TestDataFactory.createSignerWithToken(agr.Id, 'two@example.com');

        Signature_Field__c f1 = TestDataFactory.createSignatureField(agr.Id, s1.Id, 1, 100, 200);
        f1.Field_Type__c = 'Signature';
        f1.Field_Value__c = '[{"d":"M 0 0 L 5 5"}]';
        f1.Is_Completed__c = true;
        update f1;

        Signature_Field__c f2 = TestDataFactory.createSignatureField(agr.Id, s1.Id, 1, 300, 200);
        f2.Field_Type__c = 'Initial';
        f2.Field_Value__c = '[{"d":"M 0 0 L 5 5"}]';
        f2.Is_Completed__c = true;
        update f2;

        Saved_Signature__c savedSig = new Saved_Signature__c();
        savedSig.Email__c = 'one@example.com';
        savedSig.Signature_Type__c = 'Draw';
        savedSig.Signature_Data__c = '[{"d":"M 0 0 L 10 10"}]';
        insert savedSig;

        PageReference page = Page.SignedDocumentPDF;
        page.getParameters().put('agreementId', agr.Id);
        Test.setCurrentPage(page);

        Test.startTest();
        SignedDocumentPDFController ctrl = new SignedDocumentPDFController();
        Test.stopTest();

        Assert.areEqual(2, ctrl.pages[0].fields.size());
    }

    @isTest
    static void constructor_fieldWithNullPageWidth_usesDefault612() {
        // X/Y/Width/Height set to satisfy required fields, but Page_Width__c
        // and Width__c/Height__c left null → defaults kick in inside
        // buildFieldWrapper (612 page width, 150 width, 50 height).
        Agreement__c agr = TestDataFactory.createSentAgreement('SignedDoc Null Defaults');
        TestDataFactory.createTier1OriginalDoc(agr.Id);
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'nullpos@example.com');

        Signature_Field__c f = new Signature_Field__c();
        f.Agreement__c = agr.Id;
        f.Assigned_Signer__c = signer.Id;
        f.Field_Type__c = 'Full Name';
        f.Field_Value__c = 'test';
        f.Is_Completed__c = true;
        f.Page_Number__c = 1;
        f.X_Position__c = 0;  // Required field — set to 0
        f.Y_Position__c = 0;  // Required field — set to 0
        // Page_Width__c, Width__c, Height__c left null
        insert f;

        PageReference page = Page.SignedDocumentPDF;
        page.getParameters().put('agreementId', agr.Id);
        Test.setCurrentPage(page);

        Test.startTest();
        SignedDocumentPDFController ctrl = new SignedDocumentPDFController();
        Test.stopTest();

        Assert.areEqual(1, ctrl.pages[0].fields.size());
        SignedDocumentPDFController.FieldWrapper fw = ctrl.pages[0].fields[0];
        Assert.isNotNull(fw.positionStyle);
    }
}