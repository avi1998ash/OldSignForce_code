/**
 * @description : Document visibility controls per signer
 * @author      : SignForce
 */
public with sharing class DocumentVisibilityController {

    /**
     * Get visibility matrix - which signers can see which documents
     */
    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getVisibilityMatrix(Id agreementId) {
        // With the duplicate-Original purge in DocumentService.linkDocumentToAgreement
        // there is normally a single Original. In edge cases where more than one
        // exists, surface the newest so the grid never resolves to a replaced file.
        List<Agreement_Document__c> docs = [
            SELECT Id, Name, Document_Type__c, Content_Version_ID__c
            FROM Agreement_Document__c
            WHERE Agreement__c = :agreementId
            AND Document_Type__c = 'Original'
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];

        List<Signer__c> signers = [
            SELECT Id, Name, Email__c
            FROM Signer__c
            WHERE Agreement__c = :agreementId
            WITH USER_MODE
            ORDER BY Signing_Order__c ASC
        ];

        // Get existing access records
        Set<Id> docIds = new Set<Id>();
        Set<Id> signerIds = new Set<Id>();
        for (Agreement_Document__c d : docs) docIds.add(d.Id);
        for (Signer__c s : signers) signerIds.add(s.Id);

        List<Document_Signer_Access__c> accessRecords = [
            SELECT Agreement_Document__c, Signer__c, Can_View__c
            FROM Document_Signer_Access__c
            WHERE Agreement_Document__c IN :docIds
            AND Signer__c IN :signerIds
            WITH USER_MODE
        ];

        // Build access map
        Map<String, Boolean> accessMap = new Map<String, Boolean>();
        for (Document_Signer_Access__c a : accessRecords) {
            accessMap.put(a.Agreement_Document__c + ':' + a.Signer__c, a.Can_View__c);
        }

        // Build document list
        List<Map<String, Object>> docList = new List<Map<String, Object>>();
        for (Agreement_Document__c d : docs) {
            Map<String, Object> dm = new Map<String, Object>();
            dm.put('id', d.Id);
            dm.put('name', d.Name);
            dm.put('type', d.Document_Type__c);
            docList.add(dm);
        }

        // Build signer list
        List<Map<String, Object>> signerList = new List<Map<String, Object>>();
        for (Signer__c s : signers) {
            Map<String, Object> sm = new Map<String, Object>();
            sm.put('id', s.Id);
            sm.put('name', s.Name);
            sm.put('email', s.Email__c);
            signerList.add(sm);
        }

        // Build matrix
        List<Map<String, Object>> matrix = new List<Map<String, Object>>();
        for (Agreement_Document__c d : docs) {
            for (Signer__c s : signers) {
                String key = d.Id + ':' + s.Id;
                Map<String, Object> cell = new Map<String, Object>();
                cell.put('docId', d.Id);
                cell.put('signerId', s.Id);
                cell.put('docName', d.Name);
                cell.put('signerName', s.Name);
                // Default to true if no access record exists
                cell.put('canView', accessMap.containsKey(key) ? accessMap.get(key) : true);
                matrix.add(cell);
            }
        }

        Map<String, Object> result = new Map<String, Object>();
        result.put('documents', docList);
        result.put('signers', signerList);
        result.put('matrix', matrix);
        return result;
    }

    /**
     * Update visibility for a specific document-signer pair
     */
    @AuraEnabled
    public static void updateVisibility(Id documentId, Id signerId, Boolean canView) {
        List<Document_Signer_Access__c> existing = [
            SELECT Id, Can_View__c
            FROM Document_Signer_Access__c
            WHERE Agreement_Document__c = :documentId
            AND Signer__c = :signerId
            WITH USER_MODE
            LIMIT 1
        ];

        if (!existing.isEmpty()) {
            existing[0].Can_View__c = canView;
            Database.update(existing, true, AccessLevel.USER_MODE);
        } else {
            Document_Signer_Access__c access = new Document_Signer_Access__c();
            access.Agreement_Document__c = documentId;
            access.Signer__c = signerId;
            access.Can_View__c = canView;
            Database.insert(access, true, AccessLevel.USER_MODE);
        }
    }

    /**
     * Check if a signer can view a specific document
     * Used by signing viewer to filter visible documents
     */
    @AuraEnabled
    public static Boolean canSignerViewDocument(Id documentId, Id signerId) {
        List<Document_Signer_Access__c> access = [
            SELECT Can_View__c
            FROM Document_Signer_Access__c
            WHERE Agreement_Document__c = :documentId
            AND Signer__c = :signerId
            WITH USER_MODE
            LIMIT 1
        ];
        // Default to true if no access record
        return access.isEmpty() ? true : access[0].Can_View__c;
    }

    /**
     * Initialize visibility for all signers on a document (all can view by default)
     */
    @AuraEnabled
    public static void initializeVisibility(Id agreementId) {
        List<Agreement_Document__c> docs = [
            SELECT Id FROM Agreement_Document__c
            WHERE Agreement__c = :agreementId AND Document_Type__c = 'Original'
            WITH USER_MODE
        ];
        List<Signer__c> signers = [
            SELECT Id FROM Signer__c WHERE Agreement__c = :agreementId WITH USER_MODE
        ];

        List<Document_Signer_Access__c> toInsert = new List<Document_Signer_Access__c>();
        for (Agreement_Document__c d : docs) {
            for (Signer__c s : signers) {
                // Check if already exists
                List<Document_Signer_Access__c> existing = [
                    SELECT Id FROM Document_Signer_Access__c
                    WHERE Agreement_Document__c = :d.Id AND Signer__c = :s.Id
                    WITH USER_MODE
                    LIMIT 1
                ];
                if (existing.isEmpty()) {
                    Document_Signer_Access__c access = new Document_Signer_Access__c();
                    access.Agreement_Document__c = d.Id;
                    access.Signer__c = s.Id;
                    access.Can_View__c = true;
                    toInsert.add(access);
                }
            }
        }
        if (!toInsert.isEmpty()) Database.insert(toInsert, true, AccessLevel.USER_MODE);
    }
}