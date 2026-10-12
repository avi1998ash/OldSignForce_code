/**
 * Sharing: `with sharing`, and every query below also uses WITH USER_MODE, which enforces the
 * running user's sharing and field access whatever the class keyword says. This REST endpoint
 * (/services/apexrest/signing) therefore returns nothing for a Site Guest User, who has no
 * record access (verified with UserRecordAccess), and no guest permission set grants this class,
 * so a guest cannot call it at all. Nothing in the repo calls the endpoint (only
 * SigningControllerTest); the live guest signing flow uses GuestSigningApi. To open it to
 * guests it would need `without sharing` AND the WITH USER_MODE clauses removed, with
 * Access_Token__c validation as the access control.
 */
@RestResource(urlMapping='/signing/*')
global with sharing class SigningController {

    global class SigningResponse {
        global Boolean success;
        global String error;
        global String signerId;
        global String agreementId;
        global String agreementName;
        global String message;
        global String signerEmail;
        global List<Signature_Field__c> fields;
        global List<Agreement_Document__c> documents;
    }

    @HttpGet
    global static SigningResponse getSigningData() {
        SigningResponse res = new SigningResponse();
        RestRequest req = RestContext.request;
        String token = req.params.get('token');

        if (String.isBlank(token)) {
            res.success = false;
            res.error = 'Invalid token';
            return res;
        }

        List<Signer__c> signers = [
            SELECT Id, Email__c, Status__c, Agreement__c
            FROM Signer__c WHERE Access_Token__c = :token WITH USER_MODE LIMIT 1
        ];

        if (signers.isEmpty()) {
            res.success = false;
            res.error = 'Invalid or expired link';
            return res;
        }

        Signer__c signer = signers[0];
        Id agrId = signer.Agreement__c;

        Agreement__c agr = [
            SELECT Id, Name, Status__c, Message_to_Signers__c, Expiry_Date__c
            FROM Agreement__c WHERE Id = :agrId WITH USER_MODE LIMIT 1
        ];

        if (agr.Status__c == 'Completed') {
            res.success = false; res.error = 'This agreement has already been completed'; return res;
        }
        if (agr.Status__c == 'Voided') {
            res.success = false; res.error = 'This agreement has been voided'; return res;
        }
        if (agr.Expiry_Date__c != null && agr.Expiry_Date__c < DateTime.now()) {
            res.success = false; res.error = 'This signing link has expired'; return res;
        }
        if (signer.Status__c == 'Signed') {
            res.success = false; res.error = 'You have already signed this document'; return res;
        }

        List<Signature_Field__c> fields = [
            SELECT Id, Field_Type__c, Page_Number__c, X_Position__c, Y_Position__c,
                   Width__c, Height__c, Is_Required__c, Is_Completed__c
            FROM Signature_Field__c
            WHERE Agreement__c = :agrId AND Assigned_Signer__c = :signer.Id
            WITH USER_MODE
        ];

        List<Agreement_Document__c> docs = [
            SELECT Id, Name, Content_Version_ID__c, Document_Type__c, External_URL__c
            FROM Agreement_Document__c
            WHERE Agreement__c = :agrId AND Document_Type__c = 'Original'
            WITH USER_MODE
        ];

        AuditTrailServiceGuest.log(agrId, 'Document Viewed', signer.Email__c,
            RestContext.request.remoteAddress,
            RestContext.request.headers.get('User-Agent'));

        res.success = true;
        res.signerId = signer.Id;
        res.agreementId = agrId;
        res.agreementName = agr.Name;
        res.message = agr.Message_to_Signers__c;
        res.signerEmail = signer.Email__c;
        res.fields = fields;
        res.documents = docs;
        return res;
    }
}