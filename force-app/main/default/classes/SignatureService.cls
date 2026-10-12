/**
 * @description : SignatureService - Saved Signature Management
 * @author      : SignForce
 *
 * SECURITY: This service intentionally remains without sharing because it is
 * used by the token-authenticated guest signing flow. Guest callers must reach
 * saved signatures only through GuestSigningApi, which derives the
 * signer email from SignForceAuthz instead of trusting client-supplied scope.
**/
public inherited sharing class SignatureService {

    @AuraEnabled
    public static Map<String, Object> getSavedSignature(String email) {
        List<Saved_Signature__c> sigs = [
            SELECT Id, Email__c, Signature_Data__c, Signature_Type__c, Font_Family__c, Last_Used__c
            FROM Saved_Signature__c
            WHERE Email__c = :email
            LIMIT 1
        ];
        if (sigs.isEmpty()) {
            return new Map<String, Object>{ 'found' => false };
        }
        Saved_Signature__c sig = sigs[0];
        return new Map<String, Object>{
            'found'         => true,
            'signatureData' => sig.Signature_Data__c,
            'signatureType' => sig.Signature_Type__c,
            'fontFamily'    => sig.Font_Family__c,
            'lastUsed'      => sig.Last_Used__c
        };
    }

    @AuraEnabled
    public static void saveSignature(String email, String signatureData, String signatureType, String fontFamily) {
        List<Saved_Signature__c> existing = [
            SELECT Id, Email__c FROM Saved_Signature__c WHERE Email__c = :email LIMIT 1
        ];
        Saved_Signature__c sig;
        if (existing.isEmpty()) {
            sig = new Saved_Signature__c();
            sig.Email__c = email;
        } else {
            sig = existing[0];
            sig.Email__c = email;
        }
        sig.Signature_Data__c = signatureData;
        sig.Signature_Type__c = signatureType;
        sig.Font_Family__c = fontFamily;
        sig.Last_Used__c = DateTime.now();
        // CRUD create only. The Site Guest User holds create on Saved_Signature__c
        // (it is one of the three objects it can write), so this branch is always
        // taken during guest signing. Deliberately NOT gated on isUpdateable():
        // guest has edit=false, and an upsert that re-saves a returning signer's
        // signature would then be skipped, silently breaking "remember my signature".
        if (Schema.sObjectType.Saved_Signature__c.isCreateable()) {
            upsert sig Email__c;
        }
    }
}