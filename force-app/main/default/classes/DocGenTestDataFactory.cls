/**
 * DocGenTestDataFactory — shared fixtures for the Doc Gen test suite.
 *
 * Why a factory:
 *   The Doc Gen tests need 3-4 record types built consistently
 *   (Account/Contact source records, Document_Template__c with
 *   Template_Fields__r, ContentVersion for the template DOCX).
 *   Inlining that into every test file produced ~200 lines of
 *   duplicated boilerplate. This factory keeps each test focused on
 *   what it's actually proving.
 *
 *   Methods are kept narrow on purpose — each builds one thing well,
 *   tests compose them. No single "make me a complete generation
 *   scenario" method, because that ends up forcing test fixtures into
 *   shapes that only fit the most generic case.
 */
@isTest
public class DocGenTestDataFactory {

    /**
     * A throwaway Account that's safe to use as a merge-context source record.
     */
    public static Account makeAccount(String name) {
        Account a = new Account(Name = name);
        insert a;
        return a;
    }

    /**
     * A Document_Template__c with the bare minimum fields populated.
     * Caller passes targetObject (e.g. 'Account'). Caller can flip
     * autoCreate=true to enable the auto-create-agreement flow.
     */
    public static Document_Template__c makeTemplate(
        String name,
        String targetObject,
        String outputFormat,
        Boolean autoCreate
    ) {
        Document_Template__c t = new Document_Template__c(
            Name = name,
            Object_API_Name__c = targetObject,
            Output_Format__c = outputFormat,
            Output_Filename_Pattern__c = '{{Name}}.docx',
            Auto_Create_Agreement__c = autoCreate == true,
            Active__c = true,
            Default_Agreement_Type__c = autoCreate == true ? 'Contract' : null
        );
        insert t;
        return t;
    }

    /**
     * Shorthand: a non-auto-create DOCX template.
     */
    public static Document_Template__c makeBasicTemplate(String targetObject) {
        return makeTemplate('Test Template', targetObject, 'DOCX', false);
    }

    /**
     * Add a tag (Document_Template_Field__c) to a template.
     */
    public static Document_Template_Field__c addTag(
        Id templateId,
        String tagName,
        String fieldType
    ) {
        Document_Template_Field__c f = new Document_Template_Field__c(
            Document_Template__c = templateId,
            Tag_Name__c = tagName,
            Field_Type__c = fieldType,
            Required__c = false
        );
        insert f;
        return f;
    }

    /**
     * Insert a fake DOCX as a ContentVersion + return the file ID.
     * The bytes themselves are arbitrary — the Lambda mock returns a
     * canned response regardless of input. We just need a real
     * ContentVersion to point Template_File_Id__c at.
     *
     * Returns the ContentDocumentId (which is what Template_File_Id__c
     * is supposed to hold per the README).
     */
    public static Id makeFakeTemplateFile(String filename) {
        ContentVersion cv = new ContentVersion(
            Title = filename,
            PathOnClient = filename,
            VersionData = Blob.valueOf('PK fake docx bytes'),  // not a real DOCX, doesn't matter
            Origin = 'H'
        );
        insert cv;
        ContentVersion reloaded = [
            SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id
        ];
        return reloaded.ContentDocumentId;
    }

    /**
     * Wire a template to a fake DOCX file. The template's
     * Template_File_Id__c stores the ContentDocument Id (per README).
     * Returns the loaded template.
     */
    public static Document_Template__c attachFileToTemplate(Id templateId, String filename) {
        Id contentDocId = makeFakeTemplateFile(filename);
        Document_Template__c t = [SELECT Id FROM Document_Template__c WHERE Id = :templateId];
        t.Template_File_Id__c = contentDocId;
        update t;
        return t;
    }

    /**
     * Insert a Document_Generation_Log__c row in the given status.
     * Used by DocumentHistoryControllerTest to seed the history view.
     */
    public static Document_Generation_Log__c makeLog(
        Id templateId,
        Id sourceRecordId,
        String status
    ) {
        Document_Generation_Log__c log = new Document_Generation_Log__c(
            Document_Template__c = templateId,
            Source_Record_Id__c  = sourceRecordId,
            Source_Object_Api_Name__c = sourceRecordId != null
                ? sourceRecordId.getSObjectType().getDescribe().getName()
                : null,
            Status__c = status,
            Output_Filename__c = 'test.docx',
            Duration_Ms__c = 250
        );
        insert log;
        return log;
    }
}