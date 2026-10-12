/**
 * TemplatePaddingStripTest — the upload-time padding strip: when the converter
 * reports it removed blank-space padding, the cleaned bytes become a NEW VERSION of
 * the same template file; when it reports nothing to change, the template is left
 * exactly as it was. The queueable wrapper must never throw either way.
 */
@IsTest
private class TemplatePaddingStripTest {

    /** Switchable Lambda stub: strip requests honour `stripChanged`; anything else
     *  (e.g. the preview conversion the strip chains) gets a harmless failure. */
    private class LambdaMock implements HttpCalloutMock {
        private Boolean stripChanged;
        LambdaMock(Boolean stripChanged) { this.stripChanged = stripChanged; }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            String body = req.getBody() == null ? '' : req.getBody();
            if (body.contains('stripTagPadding')) {
                res.setBody(JSON.serialize(new Map<String, Object>{
                    'success' => true,
                    'changed' => stripChanged,
                    'removedChars' => stripChanged ? 8 : 0,
                    'paragraphs' => stripChanged ? 2 : 0,
                    'outputBase64' => stripChanged
                        ? EncodingUtil.base64Encode(Blob.valueOf('CLEANED-DOCX-BYTES'))
                        : null
                }));
            } else {
                res.setBody('{"success":false}');
            }
            return res;
        }
    }

    private static Document_Template__c makeTemplate() {
        ContentVersion cv = new ContentVersion(
            Title = 'Padding Template',
            PathOnClient = 'padding-template.docx',
            VersionData = Blob.valueOf('ORIGINAL-DOCX-BYTES'),
            Origin = 'H'
        );
        insert cv;
        Id cvId = [SELECT Id FROM ContentVersion WHERE Id = :cv.Id LIMIT 1].Id;

        Document_Template__c tpl = new Document_Template__c(
            Name = 'Padding Template',
            Object_API_Name__c = 'Account',
            Output_Format__c = 'DOCX',
            Active__c = true,
            Template_File_Id__c = cvId
        );
        insert tpl;
        return tpl;
    }

    @IsTest
    static void strip_changed_savesCleanedBytesAsNewVersionOfSameFile() {
        Document_Template__c tpl = makeTemplate();
        Id oldCvId = (Id) tpl.Template_File_Id__c;
        Id oldDocId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :oldCvId].ContentDocumentId;

        Test.setMock(HttpCalloutMock.class, new LambdaMock(true));
        Test.startTest();
        Map<String, Object> res = DocumentGenerationService.stripTemplatePadding(tpl.Id);
        Test.stopTest();

        Assert.areEqual(true, res.get('changed'), 'The strip reports it changed the file');

        Document_Template__c after = [
            SELECT Template_File_Id__c FROM Document_Template__c WHERE Id = :tpl.Id
        ];
        Assert.areNotEqual(String.valueOf(oldCvId), after.Template_File_Id__c,
            'The template now points at the cleaned ContentVersion');

        ContentVersion cleaned = [
            SELECT ContentDocumentId, VersionData FROM ContentVersion
            WHERE Id = :(Id) after.Template_File_Id__c
        ];
        Assert.areEqual(oldDocId, cleaned.ContentDocumentId,
            'Cleaned bytes are a NEW VERSION of the SAME file — the original stays in version history');
        Assert.areEqual('CLEANED-DOCX-BYTES', cleaned.VersionData.toString(),
            'The stored bytes are the converter output');
    }

    @IsTest
    static void strip_unchanged_leavesTemplateUntouched() {
        Document_Template__c tpl = makeTemplate();
        String oldCvId = tpl.Template_File_Id__c;

        Test.setMock(HttpCalloutMock.class, new LambdaMock(false));
        Test.startTest();
        Map<String, Object> res = DocumentGenerationService.stripTemplatePadding(tpl.Id);
        Test.stopTest();

        Assert.areEqual(false, res.get('changed'), 'Nothing to strip is reported as unchanged');
        Assert.areEqual(oldCvId,
            [SELECT Template_File_Id__c FROM Document_Template__c WHERE Id = :tpl.Id].Template_File_Id__c,
            'The template file pointer is untouched');
        Assert.areEqual(1, [SELECT COUNT() FROM ContentVersion
            WHERE ContentDocumentId = :[SELECT ContentDocumentId FROM ContentVersion
                                        WHERE Id = :(Id) oldCvId].ContentDocumentId],
            'No extra version was written');
    }

    @IsTest
    static void queueable_neverThrows_evenWhenNothingChanges() {
        Document_Template__c tpl = makeTemplate();
        String oldCvId = tpl.Template_File_Id__c;

        Test.setMock(HttpCalloutMock.class, new LambdaMock(false));
        Test.startTest();
        System.enqueueJob(new TemplatePaddingStripQueueable(tpl.Id));
        Test.stopTest();   // executes the queueable; its chained preview enqueue is swallowed in test

        Assert.areEqual(oldCvId,
            [SELECT Template_File_Id__c FROM Document_Template__c WHERE Id = :tpl.Id].Template_File_Id__c,
            'Queueable run leaves an unchanged template exactly as it was');
    }

    @IsTest
    static void strip_nullTemplate_isQuietNoOp() {
        Map<String, Object> res = DocumentGenerationService.stripTemplatePadding(null);
        Assert.areEqual(false, res.get('changed'), 'Null template id is a quiet no-op');
    }
}