/**
 * DocumentServiceTest — exhaustive tests for DocumentService.
 *
 * DocumentService is the internal-user document management surface.
 * Handles linking ContentVersions to Agreement_Document__c, the
 * Tier1/Tier2/Tier3 storage-tier wrapper used by the document picker,
 * ContentDistribution provisioning for guest-facing public URLs, and
 * cleanup.
 *
 * Coverage targets:
 *   - linkDocumentToAgreement (positive)
 *   - getAgreementDocuments (Tier1 + S3 + mixed + empty)
 *   - deleteAgreementDocument (positive)
 *   - getDocumentDownloadUrl (URL format)
 *   - createPublicUrlForAgreement (fresh, with-CV, with-CDL-fallback, idempotent)
 *   - getDocumentPublicUrl (set + unset)
 *
 * Together these cover ~80%+ of the class.
 */
@isTest(SeeAllData=false)
private class DocumentServiceTest {

    // ═════════════════════════════════════════════════════════════════════
    //  linkDocumentToAgreement
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void linkDocumentToAgreement_validInputs_createsAgreementDocument() {
        Agreement__c agr = TestDataFactory.createDraftAgreement('Link Doc Test');

        // Create a ContentVersion linked to the agreement
        ContentVersion cv = new ContentVersion();
        cv.Title = 'Test Original';
        cv.PathOnClient = 'original.pdf';
        cv.VersionData = Blob.valueOf('original pdf bytes');
        cv.FirstPublishLocationId = agr.Id;
        insert cv;

        ContentVersion inserted = [
            SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id
        ];

        Test.startTest();
        DocumentService.linkDocumentToAgreement(agr.Id, inserted.ContentDocumentId, 'Original');
        Test.stopTest();

        List<Agreement_Document__c> created = [
            SELECT Id, Name, Document_Type__c, Content_Version_ID__c
            FROM Agreement_Document__c
            WHERE Agreement__c = :agr.Id
        ];
        Assert.areEqual(1, created.size(), 'One Agreement_Document__c should be created');
        Assert.areEqual('Original', created[0].Document_Type__c);
        Assert.areEqual('Test Original', created[0].Name,
            'Should pick up the ContentVersion title');
        Assert.areEqual(inserted.Id, created[0].Content_Version_ID__c,
            'Content_Version_ID__c should match the latest CV');
    }

    @isTest
    static void linkDocumentToAgreement_draftReupload_purgesOldOriginal() {
        // BUG-039: re-uploading the Original on a Draft must remove the prior
        // Original so only the new one remains (no stale duplicate).
        Agreement__c agr = TestDataFactory.createDraftAgreement('Reupload Purge');

        // Pre-existing (old) Original with a stale public URL.
        Agreement_Document__c oldOriginal = TestDataFactory.createTier1OriginalDoc(agr.Id);
        oldOriginal.External_URL__c = 'https://stale.example.com/old';
        update oldOriginal;

        // New uploaded ContentVersion replacing the Original.
        ContentVersion cv = new ContentVersion();
        cv.Title = 'Replacement Original';
        cv.PathOnClient = 'replacement.pdf';
        cv.VersionData = Blob.valueOf('replacement pdf bytes');
        cv.FirstPublishLocationId = agr.Id;
        insert cv;
        ContentVersion inserted = [
            SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id
        ];

        Test.startTest();
        DocumentService.linkDocumentToAgreement(agr.Id, inserted.ContentDocumentId, 'Original');
        Test.stopTest();

        List<Agreement_Document__c> originals = [
            SELECT Id, Name, Content_Version_ID__c, External_URL__c
            FROM Agreement_Document__c
            WHERE Agreement__c = :agr.Id AND Document_Type__c = 'Original'
        ];
        Assert.areEqual(1, originals.size(),
            'Old Original should be purged, leaving exactly one');
        Assert.areEqual(inserted.Id, originals[0].Content_Version_ID__c,
            'Remaining Original should point at the new ContentVersion');
        Assert.areEqual(0,
            [SELECT COUNT() FROM Agreement_Document__c WHERE Id = :oldOriginal.Id],
            'The prior Original record should be deleted');
        // BUG-040: new Original must not carry a stale public URL.
        Assert.isNull(originals[0].External_URL__c,
            'New Original must have External_URL__c null so it regenerates');
    }

    @isTest
    static void linkDocumentToAgreement_sentAgreement_doesNotPurgeOriginal() {
        // BUG-039 cleanup is scoped to Draft only. On a Sent agreement, an
        // existing Original must be preserved (we still insert the new linkage
        // but never delete the prior Original).
        Agreement__c agr = TestDataFactory.createSentAgreement('Reupload Sent NoPurge');
        Agreement_Document__c oldOriginal = TestDataFactory.createTier1OriginalDoc(agr.Id);

        ContentVersion cv = new ContentVersion();
        cv.Title = 'Sent Re-link';
        cv.PathOnClient = 'sent.pdf';
        cv.VersionData = Blob.valueOf('sent pdf bytes');
        cv.FirstPublishLocationId = agr.Id;
        insert cv;
        ContentVersion inserted = [
            SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id
        ];

        Test.startTest();
        DocumentService.linkDocumentToAgreement(agr.Id, inserted.ContentDocumentId, 'Original');
        Test.stopTest();

        Assert.areEqual(1,
            [SELECT COUNT() FROM Agreement_Document__c WHERE Id = :oldOriginal.Id],
            'On a non-Draft agreement the prior Original must be preserved');
        Assert.areEqual(2,
            [SELECT COUNT() FROM Agreement_Document__c
             WHERE Agreement__c = :agr.Id AND Document_Type__c = 'Original'],
            'Both Originals should remain on a Sent agreement (no purge)');
    }

    @isTest
    static void linkDocumentToAgreement_nonOriginalType_doesNotPurgeOriginal() {
        // Only documentType=='Original' triggers the purge. Linking a different
        // type (e.g. Signed) must leave the existing Original untouched.
        Agreement__c agr = TestDataFactory.createDraftAgreement('Link NonOriginal');
        Agreement_Document__c original = TestDataFactory.createTier1OriginalDoc(agr.Id);

        ContentVersion cv = new ContentVersion();
        cv.Title = 'Signed Copy';
        cv.PathOnClient = 'signed.pdf';
        cv.VersionData = Blob.valueOf('signed pdf bytes');
        cv.FirstPublishLocationId = agr.Id;
        insert cv;
        ContentVersion inserted = [
            SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id
        ];

        Test.startTest();
        DocumentService.linkDocumentToAgreement(agr.Id, inserted.ContentDocumentId, 'Signed');
        Test.stopTest();

        Assert.areEqual(1,
            [SELECT COUNT() FROM Agreement_Document__c
             WHERE Agreement__c = :agr.Id AND Document_Type__c = 'Original'],
            'Existing Original must remain when linking a non-Original type');
        Assert.areEqual(1,
            [SELECT COUNT() FROM Agreement_Document__c WHERE Id = :original.Id],
            'Original record should not be deleted');
        Assert.areEqual(1,
            [SELECT COUNT() FROM Agreement_Document__c
             WHERE Agreement__c = :agr.Id AND Document_Type__c = 'Signed'],
            'New Signed document should be linked');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  getAgreementDocuments — covers DocWrapper construction
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void getAgreementDocuments_tier1Only_returnsWrappedDocs() {
        Agreement__c agr = TestDataFactory.createDraftAgreement('GetDocs Tier1');
        Agreement_Document__c d = TestDataFactory.createTier1OriginalDoc(agr.Id);

        Test.startTest();
        List<DocumentService.DocWrapper> wrappers = DocumentService.getAgreementDocuments(agr.Id);
        Test.stopTest();

        Assert.areEqual(1, wrappers.size());
        DocumentService.DocWrapper w = wrappers[0];
        Assert.areEqual(d.Id, w.Id);
        Assert.areEqual('Original', w.documentType);
        Assert.areEqual('Tier1', w.storageTier);
        Assert.isNotNull(w.contentVersionId, 'Tier1 should expose contentVersionId');
        Assert.isNull(w.s3DocumentId, 'Tier1 should not have s3DocumentId');
        // FileType should be set from the ContentVersion ('PDF' from FileType column)
        Assert.isNotNull(w.fileType, 'Tier1 should expose fileType from ContentVersion');
    }

    @isTest
    static void getAgreementDocuments_tier2S3_returnsWrappedDocsWithS3Metadata() {
        Agreement__c agr = TestDataFactory.createDraftAgreement('GetDocs Tier2');
        Agreement_Document__c d = TestDataFactory.createS3OriginalDoc(agr.Id, 'Tier2');

        Test.startTest();
        List<DocumentService.DocWrapper> wrappers = DocumentService.getAgreementDocuments(agr.Id);
        Test.stopTest();

        Assert.areEqual(1, wrappers.size());
        DocumentService.DocWrapper w = wrappers[0];
        Assert.areEqual(d.Id, w.Id);
        Assert.areEqual('Tier2', w.storageTier);
        Assert.isNotNull(w.s3DocumentId, 'Tier2 should have s3DocumentId');
        Assert.isNotNull(w.s3PreviewUrl, 'Tier2 should have s3PreviewUrl');
        // No ContentVersion → fileType inferred from the name extension.
        // Factory default name is 'Test S3 Document' — no extension → fileType '' (empty).
        Assert.areEqual('', w.fileType,
            'S3 doc without .pdf extension should have empty fileType');
    }

    @isTest
    static void getAgreementDocuments_tier3S3_withPdfNameInfersFileType() {
        // S3 doc with .pdf in the name should infer 'PDF' file type
        Agreement__c agr = TestDataFactory.createDraftAgreement('GetDocs Tier3 Named');
        Agreement_Document__c d = TestDataFactory.createS3OriginalDoc(agr.Id, 'Tier3');
        d.Name = 'BigContract.pdf';
        update d;

        Test.startTest();
        List<DocumentService.DocWrapper> wrappers = DocumentService.getAgreementDocuments(agr.Id);
        Test.stopTest();

        DocumentService.DocWrapper w = wrappers[0];
        Assert.areEqual('PDF', w.fileType,
            'S3 doc named *.pdf should infer fileType=PDF from extension');
    }

    @isTest
    static void getAgreementDocuments_mixedTiers_returnsAll() {
        Agreement__c agr = TestDataFactory.createDraftAgreement('GetDocs Mixed');
        TestDataFactory.createTier1OriginalDoc(agr.Id);
        // Add a second doc — Stamped/Tier3 to verify ordering + mixed handling
        Agreement_Document__c stamped = new Agreement_Document__c();
        stamped.Agreement__c = agr.Id;
        stamped.Name = 'StampedDoc.docx';
        stamped.Document_Type__c = 'Stamped';
        stamped.Storage_Tier__c = 'Tier3';
        stamped.S3_Document_ID__c = 'stamped_s3_' + DateTime.now().getTime();
        insert stamped;

        Test.startTest();
        List<DocumentService.DocWrapper> wrappers = DocumentService.getAgreementDocuments(agr.Id);
        Test.stopTest();

        Assert.areEqual(2, wrappers.size(), 'Both docs should come back');

        // Verify the .docx file gets WORD fileType from the extension inference
        Boolean foundWord = false;
        for (DocumentService.DocWrapper w : wrappers) {
            if (w.documentType == 'Stamped') {
                foundWord = (w.fileType == 'WORD');
            }
        }
        Assert.isTrue(foundWord, 'Stamped .docx should infer WORD fileType');
    }

    @isTest
    static void getAgreementDocuments_noDocs_returnsEmptyList() {
        Agreement__c agr = TestDataFactory.createDraftAgreement('GetDocs Empty');

        Test.startTest();
        List<DocumentService.DocWrapper> wrappers = DocumentService.getAgreementDocuments(agr.Id);
        Test.stopTest();

        Assert.areEqual(0, wrappers.size(), 'No docs → empty list');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  deleteAgreementDocument
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void deleteAgreementDocument_existing_removes() {
        Agreement__c agr = TestDataFactory.createDraftAgreement('Delete Doc Test');
        Agreement_Document__c d = TestDataFactory.createTier1OriginalDoc(agr.Id);

        Test.startTest();
        DocumentService.deleteAgreementDocument(d.Id);
        Test.stopTest();

        List<Agreement_Document__c> after = [
            SELECT Id FROM Agreement_Document__c WHERE Id = :d.Id
        ];
        Assert.areEqual(0, after.size(), 'Document should be deleted');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  getDocumentDownloadUrl
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void getDocumentDownloadUrl_buildsExpectedFormat() {
        String fakeCvId = '068000000000000AAA';

        Test.startTest();
        String url = DocumentService.getDocumentDownloadUrl(fakeCvId);
        Test.stopTest();

        Assert.areEqual('/sfc/servlet.shepherd/version/download/' + fakeCvId, url,
            'URL must match the Shepherd download format');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  getContentVersionSize / deleteContentDocument (BUG-024 size guard)
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void getContentVersionSize_returnsByteSize() {
        // BUG-024: the LWC reads ContentVersion.ContentSize after upload to
        // enforce the 20 MB ceiling. Verify the byte size matches the payload.
        Agreement__c agr = TestDataFactory.createDraftAgreement('Size Check');
        Blob payload = Blob.valueOf('twenty-something bytes here');

        ContentVersion cv = new ContentVersion();
        cv.Title = 'Sized File';
        cv.PathOnClient = 'sized.pdf';
        cv.VersionData = payload;
        cv.FirstPublishLocationId = agr.Id;
        insert cv;

        ContentVersion inserted = [
            SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id
        ];

        Test.startTest();
        Integer size = DocumentService.getContentVersionSize(inserted.ContentDocumentId);
        Test.stopTest();

        Assert.areEqual(payload.size(), size,
            'getContentVersionSize should return the ContentVersion byte size');
    }

    @isTest
    static void deleteContentDocument_removesOverSizeUpload() {
        // BUG-024: an over-size file already uploaded by lightning-file-upload
        // must be deleted so it is never linked and leaves no orphan file.
        Agreement__c agr = TestDataFactory.createDraftAgreement('Delete Oversize');

        ContentVersion cv = new ContentVersion();
        cv.Title = 'Oversize File';
        cv.PathOnClient = 'oversize.pdf';
        cv.VersionData = Blob.valueOf('pretend this is huge');
        cv.FirstPublishLocationId = agr.Id;
        insert cv;

        Id cdId = [
            SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id
        ].ContentDocumentId;

        Test.startTest();
        DocumentService.deleteContentDocument(cdId);
        Test.stopTest();

        Assert.areEqual(0,
            [SELECT COUNT() FROM ContentDocument WHERE Id = :cdId],
            'Over-size ContentDocument should be deleted');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  createPublicUrlForAgreement
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void createPublicUrlForAgreement_withCv_setsExternalUrl() {
        Agreement__c agr = TestDataFactory.createDraftAgreement('PubUrl With CV');
        Agreement_Document__c d = TestDataFactory.createTier1OriginalDoc(agr.Id);

        Test.startTest();
        DocumentService.createPublicUrlForAgreement(agr.Id);
        Test.stopTest();

        Agreement_Document__c after = [
            SELECT External_URL__c FROM Agreement_Document__c WHERE Id = :d.Id
        ];
        Assert.isNotNull(after.External_URL__c, 'External_URL__c should be set');
        Assert.isTrue(String.isNotBlank(after.External_URL__c),
            'External_URL__c should be non-blank after CD provisioning');
    }

    @isTest
    static void createPublicUrlForAgreement_existingUrl_isIdempotent() {
        Agreement__c agr = TestDataFactory.createDraftAgreement('PubUrl Idempotent');
        Agreement_Document__c d = TestDataFactory.createTier1OriginalDoc(agr.Id);

        // Pre-set External_URL__c. The method should detect and return early.
        d.External_URL__c = 'https://existing.example.com/abc';
        update d;

        Test.startTest();
        DocumentService.createPublicUrlForAgreement(agr.Id);
        Test.stopTest();

        Agreement_Document__c after = [
            SELECT External_URL__c FROM Agreement_Document__c WHERE Id = :d.Id
        ];
        Assert.areEqual('https://existing.example.com/abc', after.External_URL__c,
            'Existing External_URL__c must not be overwritten');
    }

    @isTest
    static void createPublicUrlForAgreement_noCvOnDoc_fallsBackToCdlScan() {
        // No Agreement_Document__c exists yet — only a ContentDocumentLink
        // pointing at the agreement. The method should find the CV via CDL
        // and create a new Agreement_Document__c row.
        Agreement__c agr = TestDataFactory.createDraftAgreement('PubUrl CDL Fallback');

        ContentVersion cv = new ContentVersion();
        cv.Title = 'Orphan PDF';
        cv.PathOnClient = 'orphan.pdf';
        cv.VersionData = Blob.valueOf('orphan pdf bytes');
        cv.FirstPublishLocationId = agr.Id;
        insert cv;

        Test.startTest();
        DocumentService.createPublicUrlForAgreement(agr.Id);
        Test.stopTest();

        List<Agreement_Document__c> created = [
            SELECT Id, External_URL__c, Document_Type__c, Content_Version_ID__c
            FROM Agreement_Document__c
            WHERE Agreement__c = :agr.Id
        ];
        Assert.areEqual(1, created.size(),
            'Should create a new Agreement_Document__c via CDL fallback');
        Assert.areEqual('Original', created[0].Document_Type__c);
        Assert.isNotNull(created[0].External_URL__c,
            'New row should have External_URL__c populated');
    }

    @isTest
    static void createPublicUrlForAgreement_noDocsAtAll_noOp() {
        // Agreement with no original document → method should return without throwing
        Agreement__c agr = TestDataFactory.createDraftAgreement('PubUrl No Docs');

        Boolean threw = false;
        Test.startTest();
        try {
            DocumentService.createPublicUrlForAgreement(agr.Id);
        } catch (Exception anys) {
            threw = true;
        }
        Test.stopTest();

        Assert.isFalse(threw, 'Method should not throw when no docs exist');
        List<Agreement_Document__c> docs = [
            SELECT Id FROM Agreement_Document__c WHERE Agreement__c = :agr.Id
        ];
        Assert.areEqual(0, docs.size(), 'No Agreement_Document__c should be created');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  getDocumentPublicUrl
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void getDocumentPublicUrl_setOnDoc_returnsUrl() {
        Agreement__c agr = TestDataFactory.createDraftAgreement('GetPubUrl Set');
        Agreement_Document__c d = TestDataFactory.createTier1OriginalDoc(agr.Id);
        d.External_URL__c = 'https://example.com/abc';
        update d;

        Test.startTest();
        String url = DocumentService.getDocumentPublicUrl(agr.Id);
        Test.stopTest();

        Assert.areEqual('https://example.com/abc', url);
    }

    @isTest
    static void getDocumentPublicUrl_notSet_returnsNull() {
        Agreement__c agr = TestDataFactory.createDraftAgreement('GetPubUrl Unset');
        TestDataFactory.createTier1OriginalDoc(agr.Id);
        // Don't set External_URL__c

        Test.startTest();
        String url = DocumentService.getDocumentPublicUrl(agr.Id);
        Test.stopTest();

        Assert.areEqual(null, url,
            'When no External_URL__c is set, getDocumentPublicUrl should return null');
    }

    @isTest
    static void getDocumentPublicUrl_noDocs_returnsNull() {
        Agreement__c agr = TestDataFactory.createDraftAgreement('GetPubUrl NoDocs');

        Test.startTest();
        String url = DocumentService.getDocumentPublicUrl(agr.Id);
        Test.stopTest();

        Assert.areEqual(null, url, 'Agreement with no docs returns null');
    }
}