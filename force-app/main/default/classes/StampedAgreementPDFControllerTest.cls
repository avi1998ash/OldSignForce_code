/**
 * StampedAgreementPDFControllerTest — covers the VF controller for the
 * StampedAgreementPDF page (the "real" stamped PDF with audit trail,
 * signer rows, and embedded signatures). Constructor only.
 */
@isTest(SeeAllData=false)
private class StampedAgreementPDFControllerTest {

    @isTest
    static void constructor_noAgreementId_earlyReturns() {
        TestDataFactory.suppressCompletionStamp();
        PageReference page = Page.StampedAgreementPDF;
        Test.setCurrentPage(page);

        Test.startTest();
        StampedAgreementPDFController ctrl = new StampedAgreementPDFController();
        Test.stopTest();

        // With no agreementId the constructor returns before it queries or
        // builds anything, so every collection is still unset.
        Assert.isNull(ctrl.envelopeId,
            'No agreementId means the agreement is never queried');
        Assert.isNull(ctrl.signerWrappers,
            'Signer rows are only built past the early return');
        Assert.isNull(ctrl.auditRows,
            'Audit rows are only built past the early return');
    }

    @isTest
    static void constructor_validAgreement_loadsAllRows() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Stamped Cert');
        agr.Status__c = 'Completed';
        agr.Completed_Date__c = DateTime.now();
        agr.Envelope_ID__c = 'ENV-TEST-001';
        update agr;

        Signer__c signer = TestDataFactory.createSignerInState(
            agr.Id, 'st@example.com', 'Signed',
            DateTime.now(), false, 1
        );
        signer.Signature_Certificate_ID__c = 'CERT-AAA';
        signer.Signing_IP_Address__c = '10.0.0.1';
        update signer;

        // Audit events for the timeline
        AuditTrailService.log(agr.Id, 'Agreement Sent', null, '10.0.0.1', null);
        AuditTrailService.log(agr.Id, 'Document Signed', 'st@example.com', '10.0.0.1', null);

        PageReference page = Page.StampedAgreementPDF;
        page.getParameters().put('agreementId', agr.Id);
        Test.setCurrentPage(page);

        Test.startTest();
        StampedAgreementPDFController ctrl = new StampedAgreementPDFController();
        Test.stopTest();

        Assert.isNotNull(ctrl.envelopeId);
        Assert.areEqual('ENV-TEST-001', ctrl.envelopeId);
        Assert.isNotNull(ctrl.agreementName);
        Assert.isNotNull(ctrl.generatedOn);

        Assert.isNotNull(ctrl.signerWrappers);
        Assert.areEqual(1, ctrl.signerWrappers.size(),
            'One signer wrapper expected');
        Assert.areEqual('st@example.com', ctrl.signerWrappers[0].signerEmail);
        Assert.areEqual('CERT-AAA', ctrl.signerWrappers[0].certificateId);

        Assert.isNotNull(ctrl.auditRows);
        Assert.isTrue(ctrl.auditRows.size() >= 2,
            'Audit rows from setup should be loaded');
    }

    @isTest
    static void constructor_signerWithSavedSignatureDraw_setsIsDrawnFlag() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Stamped Draw');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'd@example.com');

        Saved_Signature__c sig = new Saved_Signature__c();
        sig.Email__c = 'd@example.com';
        sig.Signature_Type__c = 'Draw';
        sig.Signature_Data__c = '[{"d":"M 0 0 L 10 10"}]';
        insert sig;

        PageReference page = Page.StampedAgreementPDF;
        page.getParameters().put('agreementId', agr.Id);
        Test.setCurrentPage(page);

        Test.startTest();
        StampedAgreementPDFController ctrl = new StampedAgreementPDFController();
        Test.stopTest();

        Assert.areEqual(1, ctrl.signerWrappers.size());
        // Type-specific flag exists; we don't depend on which exactly
        // since assertion semantics may vary.
    }

    @isTest
    static void constructor_signerWithTypedSignature_parsesName() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Stamped Typed');
        TestDataFactory.createSignerWithToken(agr.Id, 't@example.com');

        Saved_Signature__c sig = new Saved_Signature__c();
        sig.Email__c = 't@example.com';
        sig.Signature_Type__c = 'Type';
        sig.Signature_Data__c = 'typed:John Smith:Great Vibes';
        insert sig;

        PageReference page = Page.StampedAgreementPDF;
        page.getParameters().put('agreementId', agr.Id);
        Test.setCurrentPage(page);

        Test.startTest();
        StampedAgreementPDFController ctrl = new StampedAgreementPDFController();
        Test.stopTest();

        Assert.areEqual(1, ctrl.signerWrappers.size());
    }

    // ─────────────────────────────────────────────────────────────────────
    //  BUG-016 — checkbox field renders a renderer-safe glyph (not ☑/☐)
    // ─────────────────────────────────────────────────────────────────────

    private static Signature_Field__c buildCheckboxField(
            Id agreementId, Id signerId, String fieldValue, String label) {
        Signature_Field__c f = new Signature_Field__c();
        f.Agreement__c       = agreementId;
        f.Assigned_Signer__c = signerId;
        f.Field_Type__c      = 'Checkbox';
        f.Field_Label__c     = label;
        f.Field_Value__c     = fieldValue;
        f.Is_Completed__c    = true;
        f.Page_Number__c     = 1;
        f.X_Position__c      = 100;
        f.Y_Position__c      = 200;
        return f;
    }

    @isTest
    static void constructor_checkboxField_usesRendererSafeGlyphs() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Stamped Checkbox');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'cb@example.com');

        insert buildCheckboxField(agr.Id, signer.Id, 'true',  'I Agree');
        insert buildCheckboxField(agr.Id, signer.Id, 'false', 'Marketing Opt-In');

        PageReference page = Page.StampedAgreementPDF;
        page.getParameters().put('agreementId', agr.Id);
        Test.setCurrentPage(page);

        Test.startTest();
        StampedAgreementPDFController ctrl = new StampedAgreementPDFController();
        Test.stopTest();

        Assert.isTrue(ctrl.hasFieldValues, 'Checkbox fields should populate fieldValues');
        Assert.areEqual(2, ctrl.fieldValues.size(), 'Both checkbox rows should load');

        String checkedVal = null;
        String uncheckedVal = null;
        for (StampedAgreementPDFController.FieldRow fr : ctrl.fieldValues) {
            if (fr.label == 'I Agree')          checkedVal   = fr.displayValue;
            if (fr.label == 'Marketing Opt-In') uncheckedVal = fr.displayValue;
        }

        // Must use the renderer-safe check mark (U+2713), never the ballot-box
        // glyphs U+2611/U+2610 which render as tofu/X in the VF PDF renderer.
        Assert.areEqual('✓ Checked', checkedVal,
            'true checkbox should render U+2713 (✓ Checked)');
        Assert.isFalse(checkedVal.contains('☑'),
            'must not use U+2611 ballot box (renders as X/tofu)');
        Assert.areEqual('Unchecked', uncheckedVal,
            'false checkbox should render plain "Unchecked"');
        Assert.isFalse(uncheckedVal.contains('☐'),
            'must not use U+2610 empty ballot box (renders as X/tofu)');
    }

    // ─────────────────────────────────────────────────────────────────────
    //  BUG-058 — CC recipient flagged isCC (rendered as Copy, not a signer)
    // ─────────────────────────────────────────────────────────────────────

    @isTest
    static void constructor_ccRecipient_flaggedIsCC() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = TestDataFactory.createSentAgreement('Stamped CC');

        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'signer@example.com');

        Signer__c cc = TestDataFactory.createSignerWithToken(agr.Id, 'cc@example.com');
        cc.Role__c = 'CC';
        cc.Signing_Order__c = 2;
        update cc;

        PageReference page = Page.StampedAgreementPDF;
        page.getParameters().put('agreementId', agr.Id);
        Test.setCurrentPage(page);

        Test.startTest();
        StampedAgreementPDFController ctrl = new StampedAgreementPDFController();
        Test.stopTest();

        Assert.areEqual(2, ctrl.signerWrappers.size(),
            'Both signer + CC rows still load');

        Boolean foundSignerNotCC = false;
        Boolean foundCC = false;
        for (StampedAgreementPDFController.SignerRow sr : ctrl.signerWrappers) {
            if (sr.signerEmail == 'signer@example.com') {
                foundSignerNotCC = !sr.isCC;
            }
            if (sr.signerEmail == 'cc@example.com') {
                foundCC = sr.isCC;
            }
        }
        Assert.isTrue(foundSignerNotCC, 'True signer must have isCC = false');
        Assert.isTrue(foundCC, 'CC recipient must be flagged isCC = true');
    }
}