/**
 * AgreementFileCleanupTest — the completed-agreement file sweep keeps exactly the
 * right survivors: the pointed-at final document, the certificate, and anything a
 * user uploaded. Intermediate per-signature stamps and orphaned duplicate finals
 * go; nothing else is ever touched.
 */
@IsTest
private class AgreementFileCleanupTest {

    private static Agreement__c makeAgreement(String name) {
        Agreement__c agr = new Agreement__c(Name = name, Status__c = 'Completed');
        insert agr;
        return agr;
    }

    /** Publishes a file on the agreement; returns its ContentVersion Id. */
    private static Id makeFile(Id agreementId, String title) {
        ContentVersion cv = new ContentVersion(
            Title = title,
            PathOnClient = title.replaceAll('[^a-zA-Z0-9._-]', '_') + '.pdf',
            VersionData = Blob.valueOf('%PDF-1.4 ' + title),
            Origin = 'H',
            FirstPublishLocationId = agreementId
        );
        insert cv;
        return [SELECT Id FROM ContentVersion WHERE Id = :cv.Id LIMIT 1].Id;
    }

    private static Set<String> remainingTitles(Id agreementId) {
        Set<Id> docIds = new Set<Id>();
        for (ContentDocumentLink l : [
            SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId = :agreementId
        ]) docIds.add(l.ContentDocumentId);
        Set<String> titles = new Set<String>();
        for (ContentDocument c : [SELECT Title FROM ContentDocument WHERE Id IN :docIds]) {
            titles.add(c.Title);
        }
        return titles;
    }

    @IsTest
    static void sweep_removesIntermediatesAndOrphanFinal_keepsEverythingElse() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = makeAgreement('Cleanup NDA');

        Id pointedFinalCv = makeFile(agr.Id, 'Cleanup NDA - Final Signed Document');
        makeFile(agr.Id, 'Cleanup NDA - Final Signed Document');          // orphan duplicate
        makeFile(agr.Id, 'Cleanup NDA - Signed 1 of 2 - Alice Example');  // intermediate
        makeFile(agr.Id, 'Cleanup NDA - Signing Certificate');
        makeFile(agr.Id, 'Quarterly Report.pdf');                          // user upload

        // The Stamped pointer anchors ONE of the finals — that copy must survive.
        insert new Agreement_Document__c(
            Agreement__c = agr.Id,
            Name = 'Cleanup NDA - Final Signed Document',
            Document_Type__c = 'Stamped',
            Content_Version_ID__c = pointedFinalCv,
            Storage_Tier__c = 'Tier1'
        );

        Test.startTest();
        Integer removed = AgreementFileCleanup.removeSupersededFiles(agr.Id);
        Test.stopTest();

        Assert.areEqual(2, removed, 'The orphan final and the intermediate stamp go');

        Set<String> left = remainingTitles(agr.Id);
        Assert.isTrue(left.contains('Cleanup NDA - Final Signed Document'),
            'The pointed-at final survives');
        Assert.isTrue(left.contains('Cleanup NDA - Signing Certificate'),
            'The certificate is never touched');
        Assert.isTrue(left.contains('Quarterly Report.pdf'),
            'A user upload is never touched');
        Assert.isFalse(left.contains('Cleanup NDA - Signed 1 of 2 - Alice Example'),
            'Intermediate stamps are removed');

        // Exactly one final remains — the duplicate is gone.
        Integer finals = 0;
        Set<Id> docIds = new Set<Id>();
        for (ContentDocumentLink l : [
            SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId = :agr.Id
        ]) docIds.add(l.ContentDocumentId);
        for (ContentDocument c : [SELECT Title FROM ContentDocument WHERE Id IN :docIds]) {
            if (c.Title == 'Cleanup NDA - Final Signed Document') finals++;
        }
        Assert.areEqual(1, finals, 'Exactly one Final Signed Document remains');
    }

    @IsTest
    static void sweep_collapsesRedundantStampedRows() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = makeAgreement('Race NDA');

        // The completion race produced two Stamped rows, each with its own file.
        Id cvA = makeFile(agr.Id, 'Race NDA - Final Signed Document');
        Id cvB = makeFile(agr.Id, 'Race NDA - Final Signed Document');
        insert new List<Agreement_Document__c>{
            new Agreement_Document__c(Agreement__c = agr.Id, Name = 'Race NDA - Final Signed Document',
                Document_Type__c = 'Stamped', Content_Version_ID__c = cvA, Storage_Tier__c = 'Tier1'),
            new Agreement_Document__c(Agreement__c = agr.Id, Name = 'Race NDA - Final Signed Document',
                Document_Type__c = 'Stamped', Content_Version_ID__c = cvB, Storage_Tier__c = 'Tier1')
        };

        Test.startTest();
        AgreementFileCleanup.removeSupersededFiles(agr.Id);
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM Agreement_Document__c
            WHERE Agreement__c = :agr.Id AND Document_Type__c = 'Stamped'],
            'The redundant Stamped row is collapsed to one');

        Integer finals = 0;
        for (String t : remainingTitles(agr.Id)) {
            if (t == 'Race NDA - Final Signed Document') finals++;
        }
        Assert.areEqual(1, finals, 'Only the surviving row\'s file remains');
    }

    @IsTest
    static void sweep_nothingToDo_removesNothing() {
        TestDataFactory.suppressCompletionStamp();
        Agreement__c agr = makeAgreement('Tidy NDA');
        Id finalCv = makeFile(agr.Id, 'Tidy NDA - Final Signed Document');
        makeFile(agr.Id, 'Tidy NDA - Signing Certificate');
        insert new Agreement_Document__c(
            Agreement__c = agr.Id, Name = 'Tidy NDA - Final Signed Document',
            Document_Type__c = 'Stamped', Content_Version_ID__c = finalCv, Storage_Tier__c = 'Tier1'
        );

        Test.startTest();
        Integer removed = AgreementFileCleanup.removeSupersededFiles(agr.Id);
        Integer swept = AgreementFileCleanup.cleanupCompleted(5);
        Test.stopTest();

        Assert.areEqual(0, removed, 'An already-tidy agreement loses nothing');
        Assert.areEqual(0, swept, 'The completed sweep finds nothing to remove either');
        Assert.areEqual(2, remainingTitles(agr.Id).size(), 'Both files still present');
    }

    @IsTest
    static void sweep_badInput_returnsZero() {
        TestDataFactory.suppressCompletionStamp();
        Assert.areEqual(0, AgreementFileCleanup.removeSupersededFiles(null),
            'Null agreement id is a quiet no-op');
    }
}