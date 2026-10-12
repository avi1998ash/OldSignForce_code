/**
* @description       : AgreementService - Core eSignature Business Logic
* @author            : SignForce
* @last modified on  : 05-12-2026
* @note              : Now "with sharing". The guest-facing signing logic has copies in
*                     AgreementServiceGuest (without sharing). The originals below are kept
*                     unchanged for non-guest callers until the dead-code removal pass.
**/ 
public with sharing class AgreementService {
    
    private static final Integer TOKEN_EXPIRY_HOURS = 48;

    // Resolve the org default timezone once and cache it so every formatted
    // timestamp (emails, certs, stamped copies) renders in the SAME local zone
    // with a zone label, instead of raw UTC.
    private static String ORG_TZ;
    private static String orgTz() {
        if (ORG_TZ == null) {
            ORG_TZ = [SELECT TimeZoneSidKey FROM Organization LIMIT 1].TimeZoneSidKey;
        }
        return ORG_TZ;
    }

    // Public so other email-sending classes (CommentController,
    // DocumentHistoryController, …) resolve the SAME admin-selected Org-Wide
    // Email Address — every SignForce email then originates from one address.
    /** Sender_Email_Mode__c values. Blank behaves as ORG_WIDE. */
    public static final String SENDER_MODE_ORG_WIDE     = 'OrgWide';
    public static final String SENDER_MODE_CURRENT_USER = 'CurrentUser';

    public static String getOwaId() {
        try {
            SignForce_Admin_Config__c cfg = SignForce_Admin_Config__c.getOrgDefaults();

            // 0. "Send as the sender" — returning null leaves the From address
            //    unset, which makes Salesforce send as the running user. Only
            //    honoured for a real Salesforce user: during guest signing the
            //    running user is the Site Guest User, whose mailbox is not a real
            //    address, so those emails must still go out from the org-wide one.
            if (cfg != null && cfg.Sender_Email_Mode__c == SENDER_MODE_CURRENT_USER
                && UserInfo.getUserType() == 'Standard') {
                return null;
            }

            // 1. ALWAYS honor the admin-selected Org-Wide Email Address
            //    (Setup → SignForce Admin Config stores the chosen
            //    OrgWideEmailAddress Id in Org_Wide_Email_Id__c). getOrgDefaults()
            //    reads the hierarchy custom setting from cache — no SOQL — so the
            //    admin's explicit choice always wins, even when other addresses
            //    exist in the org.
            if (cfg != null && String.isNotBlank(cfg.Org_Wide_Email_Id__c)) {
                return cfg.Org_Wide_Email_Id__c;
            }

            // 2. No admin selection → fall back to the first address available to
            //    all profiles, else any org-wide address.
            List<OrgWideEmailAddress> owas = [
                SELECT Id FROM OrgWideEmailAddress
                WHERE IsAllowAllProfiles = true
                LIMIT 1
            ];
            if (!owas.isEmpty()) return owas[0].Id;

            List<OrgWideEmailAddress> anyOwa = [
                SELECT Id FROM OrgWideEmailAddress
                LIMIT 1
            ];
            if (!anyOwa.isEmpty()) return anyOwa[0].Id;

        } catch (Exception e) {
            System.debug('getOwaId: could not resolve OWA — ' + e.getMessage());
        }
        return null;
    }
    private static final Integer MAX_TOKEN_VIEWS = 50; // Rate limiting
    
    // Hybrid attachment thresholds
    // Salesforce single-email API caps total attachment size around 10MB. Stay under it.
    private static final Long MAX_TOTAL_ATTACHMENT_BYTES = 3145728L;  // 3 MB - dev-edition orgs convert to stubs above ~3MB combined
    private static final Long MAX_SINGLE_ATTACHMENT_BYTES = 3145728L; // 3 MB single
    
    /**
* Universal document-bytes resolver. Returns the PDF as a Blob regardless of
* whether it lives in ContentVersion (Tier1) or S3 (Tier2/Tier3).
*
* Returns null on any failure so callers degrade gracefully.
* Requires callouts-enabled context for S3-backed docs.
*/
    // public static Blob getDocumentBytes(Agreement_Document__c doc) {
    //     if (doc == null) return null;
    
    //     // Try ContentVersion path (Tier1 original)
    //     if (String.isNotBlank(doc.Content_Version_ID__c)) {
    //         try {
    //             ContentVersion cv = [
    //                 SELECT VersionData FROM ContentVersion
    //                 WHERE Id = :doc.Content_Version_ID__c LIMIT 1
    //             ];
    //             System.debug('getDocumentBytes: CV path success for ' + doc.Id);
    //             return cv.VersionData;
    //         } catch (Exception e) {
    //             System.debug('getDocumentBytes: CV fetch failed for ' + doc.Id + ': ' + e.getMessage());
    //             // Don't return null — fall through to S3 path if available
    //         }
    //     }
    
    //     if (String.isBlank(doc.S3_Document_ID__c)) {
    //         System.debug('getDocumentBytes: doc has neither CV nor S3 ID: ' + doc.Id);
    //         return null;
    //     }
    
    //     // Try S3 path
    //     try {
    //         System.debug('getDocumentBytes: S3 path attempt for ' + doc.S3_Document_ID__c);
    //         String presignedUrl = getS3PresignedUrlForDoc(doc.S3_Document_ID__c);
    //         if (String.isBlank(presignedUrl)) {
    //             System.debug('getDocumentBytes: presigned URL blank');
    //             return null;
    //         }
    
    //         HttpRequest pdfReq = new HttpRequest();
    //         pdfReq.setEndpoint(presignedUrl);
    //         pdfReq.setMethod('GET');
    //         pdfReq.setTimeout(120000);
    //         pdfReq.setHeader('Accept', 'application/pdf');
    //         HttpResponse pdfRes = new Http().send(pdfReq);
    //         if (pdfRes.getStatusCode() != 200) {
    //             System.debug('getDocumentBytes: S3 GET HTTP ' + pdfRes.getStatusCode());
    //             return null;
    //         }
    //         Blob result = pdfRes.getBodyAsBlob();
    //         System.debug('getDocumentBytes: ✅ S3 fetched ' + result.size() + ' bytes');
    //         return result;
    //     } catch (Exception e) {
    //         System.debug('getDocumentBytes: S3 fetch failed: ' + e.getMessage());
    //         return null;
    //     }
    // }
    
    public static Blob getDocumentBytes(Agreement_Document__c doc) {
        // Default overload — ORIGINAL behaviour (CV first, whatever its type).
        // Used by hashing/verification so existing Document_Hash__c values stay
        // consistent and no new callouts are introduced in those paths.
        return getDocumentBytes(doc, false);
    }

    public static Blob getDocumentBytes(Agreement_Document__c doc, Boolean preferPdfOverWordCv) {
        if (doc == null) return null;
        
        // Path 1: ContentVersion (Tier1 original or Certificate)
        if (String.isNotBlank(doc.Content_Version_ID__c)) {
            try {
                ContentVersion cv = [
                    SELECT VersionData, FileExtension FROM ContentVersion
                    WHERE Id = :doc.Content_Version_ID__c LIMIT 1
                ];
                String cvExt = cv.FileExtension != null ? cv.FileExtension.toLowerCase() : '';
                if (preferPdfOverWordCv && (cvExt == 'doc' || cvExt == 'docx')) {
                    // EMAIL PATH ONLY: the CV behind this record is a WORD file
                    // (e.g. the original DOCX of an auto-created agreement).
                    // Emailing those bytes as ".pdf" produces a corrupt
                    // attachment, so skip the CV and fall through to the S3
                    // copy below — that's the converted PDF.
                    System.debug('getDocumentBytes: CV is Word (' + cvExt + '), using S3 PDF instead');
                } else {
                    System.debug('getDocumentBytes: CV path success for ' + doc.Id);
                    return cv.VersionData;
                }
            } catch (Exception e) {
                System.debug('getDocumentBytes: CV fetch failed: ' + e.getMessage());
            }
        }
        
        // Path 2: S3-backed (Stamped or Tier2/Tier3)
        if (String.isBlank(doc.S3_Document_ID__c)) {
            System.debug('getDocumentBytes: no CV or S3 ID');
            return null;
        }
        
        System.debug('getDocumentBytes: S3 path attempt for ' + doc.S3_Document_ID__c);
        
        // Try the cached presigned URL FIRST (set at stamping time, no callout needed)
        String presignedUrl = doc.S3_Preview_URL__c;
        Boolean isCachedUrlExpired = false;
        
        // S3 presigned URLs expire after 24 hours typically. Check timestamp in URL.
        if (String.isNotBlank(presignedUrl)) {
            // Try the cached URL first — no Lambda callout needed
            try {
                HttpRequest pdfReq = new HttpRequest();
                pdfReq.setEndpoint(presignedUrl);
                pdfReq.setMethod('GET');
                pdfReq.setTimeout(120000);
                pdfReq.setHeader('Accept', 'application/pdf');
                HttpResponse pdfRes = new Http().send(pdfReq);
                
                if (pdfRes.getStatusCode() == 200) {
                    Blob result = pdfRes.getBodyAsBlob();
                    System.debug('getDocumentBytes: S3 cached URL success, ' + result.size() + ' bytes');
                    return result;
                } else if (pdfRes.getStatusCode() == 403) {
                    // 403 typically means URL expired — fall through to refresh
                    System.debug('getDocumentBytes: cached URL expired (403), refreshing');
                    isCachedUrlExpired = true;
                } else {
                    System.debug('getDocumentBytes: cached URL HTTP ' + pdfRes.getStatusCode());
                }
            } catch (Exception e) {
                System.debug('getDocumentBytes: cached URL fetch failed: ' + e.getMessage());
            }
        }
        
        // Only call Lambda for fresh URL if cached URL was missing or expired
        if (String.isBlank(presignedUrl) || isCachedUrlExpired) {
            try {
                String freshUrl = getS3PresignedUrlForDoc(doc.S3_Document_ID__c);
                if (String.isBlank(freshUrl)) {
                    System.debug('getDocumentBytes: fresh URL blank');
                    return null;
                }
                
                HttpRequest pdfReq = new HttpRequest();
                pdfReq.setEndpoint(freshUrl);
                pdfReq.setMethod('GET');
                pdfReq.setTimeout(120000);
                pdfReq.setHeader('Accept', 'application/pdf');
                HttpResponse pdfRes = new Http().send(pdfReq);
                
                if (pdfRes.getStatusCode() != 200) {
                    System.debug('getDocumentBytes: fresh URL HTTP ' + pdfRes.getStatusCode());
                    return null;
                }
                Blob result = pdfRes.getBodyAsBlob();
                System.debug('getDocumentBytes: ✅ S3 fresh URL success, ' + result.size() + ' bytes');
                return result;
            } catch (Exception e) {
                System.debug('getDocumentBytes: fresh URL fetch failed: ' + e.getMessage());
                return null;
            }
        }
        
        return null;
    }
    
    /**
* Returns a fresh presigned URL for the given S3 doc ID. Used both for fetching
* bytes inline AND for embedding download links in completion emails.
*/
    public static String getS3PresignedUrlForDoc(String s3DocId) {
        if (String.isBlank(s3DocId)) return null;
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint(SignForceConfigService.getLambdaEndpoint());
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setTimeout(30000);
            req.setBody(JSON.serialize(new Map<String, Object>{
                'action' => 'getUrl',
                    'orgId'  => UserInfo.getOrganizationId(),
                    'docId'  => s3DocId
                    }));
            HttpResponse res = new Http().send(req);
            if (res.getStatusCode() != 200) {
                System.debug('getS3PresignedUrlForDoc: Lambda HTTP ' + res.getStatusCode());
                return null;
            }
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            return (String) body.get('url');
        } catch (Exception e) {
            System.debug('getS3PresignedUrlForDoc: ' + e.getMessage());
            return null;
        }
    }
    
    
    public static Agreement__c createAgreement(String name, String agreementType, String signingOrder, String message, DateTime expiryDate) {
        Agreement__c agr = new Agreement__c();
        agr.Name = name;
        agr.Agreement_Type__c = agreementType;
        agr.Signing_Order__c = signingOrder;
        agr.Message_to_Signers__c = message;
        agr.Expiry_Date__c = expiryDate;
        agr.Status__c = 'Draft';
        agr.Storage_Location__c = 'Salesforce';
        Database.insert(agr, true);
        AuditTrailService.log(agr.Id, 'Agreement Created', UserInfo.getUserEmail(), null, null);
        return agr;
    }
    
    /**
* Validates a signing token - checks expiry, rate limiting, and status
*/
    public static Map<String, Object> validateToken(String token) {
        Map<String, Object> response = new Map<String, Object>();
        
        if (String.isBlank(token) || token.length() < 10) {
            response.put('error', 'Invalid signing link.');
            return response;
        }
        
        List<Signer__c> signers = [
            SELECT Id, Name, Email__c, Agreement__c, Status__c,
            Token_Created_Date__c, Token_Expired__c, Token_View_Count__c,
            OTP_Verified__c
            FROM Signer__c
            WHERE Access_Token__c = :token
            LIMIT 1
        ];
        
        if (signers.isEmpty()) {
            response.put('error', 'Invalid or expired signing link.');
            return response;
        }
        
        Signer__c signer = signers[0];
        
        // Check if token was manually expired
        if (signer.Token_Expired__c == true) {
            response.put('error', 'This signing link has been revoked.');
            return response;
        }
        
        // Check if already signed
        if (signer.Status__c == 'Signed') {
            response.put('error', 'You have already signed this document.');
            return response;
        }
        
        // Check if declined
        if (signer.Status__c == 'Declined') {
            response.put('error', 'This document has been declined.');
            return response;
        }
        
        // Check token expiry (48 hours)
        if (signer.Token_Created_Date__c != null) {
            DateTime expiryTime = signer.Token_Created_Date__c.addHours(TOKEN_EXPIRY_HOURS);
            if (DateTime.now() > expiryTime) {
                response.put('error', 'This signing link has expired. Please request a new one from the sender.');
                return response;
            }
        }
        
        // Rate limiting - max views
        Decimal viewCount = signer.Token_View_Count__c != null ? signer.Token_View_Count__c : 0;
        if (viewCount >= MAX_TOKEN_VIEWS) {
            response.put('error', 'This signing link has been accessed too many times. Please contact the sender.');
            return response;
        }
        
        // Check agreement status
        Agreement__c agr = [
            SELECT Id, Name, Status__c, Envelope_ID__c, Expiry_Date__c
            FROM Agreement__c WHERE Id = :signer.Agreement__c LIMIT 1
        ];
        
        if (agr.Status__c == 'Voided') {
            response.put('error', 'This agreement has been voided by the sender.');
            return response;
        }
        
        if (agr.Status__c == 'Completed') {
            response.put('error', 'This agreement has already been completed.');
            return response;
        }
        
        // Check agreement expiry date
        if (agr.Expiry_Date__c != null && DateTime.now() > agr.Expiry_Date__c) {
            response.put('error', 'This agreement has expired.');
            // Auto-expire the agreement
            agr.Status__c = 'Voided';
            agr.Void_Reason__c = 'Expired';
            agr.Voided_Date__c = DateTime.now();
            update agr;
            AuditTrailService.log(agr.Id, 'Agreement Expired', 'system@signforce.com', null, null);
            return response;
        }
        
        // Increment view count
        signer.Token_View_Count__c = viewCount + 1;
        update signer;
        
        // Log the view
        AuditTrailService.log(agr.Id, 'Document Viewed', signer.Email__c, null, null);
        
        response.put('signerId', signer.Id);
        response.put('signerEmail', signer.Email__c);
        // Signer's full name (Signer__c.Name) so the signing viewer can
        // auto-populate the "Full Name" on the signature adopt sheet instead
        // of making the signer type it. May be blank if the signer was created
        // without a name; the LWC guards against that and simply no-ops.
        response.put('signerName', signer.Name);
        response.put('agreementName', agr.Name);
        response.put('agreementId', agr.Id);
        response.put('envelopeId', agr.Envelope_ID__c);
        // Whether this signer already passed the emailed one-time-code gate —
        // the signing viewer skips the OTP screen when true.
        response.put('otpVerified', signer.OTP_Verified__c == true);
        return response;
    }
    
    public static void sendForSignature(Id agreementId) {
        sendForSignature(agreementId, null, null);
    }
    
    /**
* Sends agreement for signature, optionally overriding the email subject and
* message body. If subjectOverride or messageOverride are blank/null, the
* default subject ("Action Required: Please sign ...") and the agreement's
* Message_to_Signers__c are used.
*/
    public static void sendForSignature(Id agreementId, String subjectOverride, String messageOverride) {
        Agreement__c agr = [
            SELECT Id, Name, Status__c, Signing_Order__c, Message_to_Signers__c, Envelope_ID__c, OwnerId,
                   Completed_Date__c
            FROM Agreement__c WHERE Id = :agreementId        ];
        if (agr.Status__c != 'Draft') {
            throw new AgreementException('Only Draft agreements can be sent.');
        }
        // A completed agreement is an immutable signed record. Re-sending it
        // (even after manually flipping Status back to Draft) overwrites
        // Sent_Date, resets state mid-history and corrupts the certificate
        // and audit trail. Use the "Corrected Copy" flow for a new version.
        if (agr.Completed_Date__c != null) {
            throw new AgreementException(
                'This agreement has already been completed and cannot be re-sent. '
                + 'Create a corrected copy to send a new version.'
            );
        }
        List<Signer__c> allRecipients = [
            SELECT Id, Name, Email__c, Signing_Order__c, Status__c, Access_Token__c, Role__c
            FROM Signer__c WHERE Agreement__c = :agreementId            ORDER BY Signing_Order__c ASC NULLS LAST
        ];
        if (allRecipients.isEmpty()) {
            throw new AgreementException('Add at least one signer before sending.');
        }
        // CC-only recipients are informational: they never sign and never get a
        // signing link. They are excluded from the signing flow here and receive
        // the completed document at the end (see sendCompletionEmails). Only
        // Signers and Approvers get a signing request.
        List<Signer__c> signers = new List<Signer__c>();
        for (Signer__c s : allRecipients) {
            if (s.Role__c != 'CC') signers.add(s);
        }
        if (signers.isEmpty()) {
            throw new AgreementException(
                'Add at least one Signer or Approver before sending — CC-only recipients cannot sign.'
            );
        }
        // A signer with no fields to fill receives a link that has nothing to do
        // and can never reach "complete" — the agreement stalls. If ANY field is
        // placed on this agreement, every non-CC signer must own at least one, so
        // block the send and name whoever is unassigned. (When no fields are placed
        // at all, this is a signature-less flow and the check does not apply.)
        List<Signature_Field__c> placed = [
            SELECT Assigned_Signer__c, Field_Type__c, Field_Label__c, Page_Number__c
            FROM Signature_Field__c
            WHERE Agreement__c = :agreementId        ];
        if (!placed.isEmpty()) {
            Set<Id> signersWithFields = new Set<Id>();
            // A field left unassigned belongs to nobody: it is never offered to any
            // signer, so it can never be filled, and it prints on the finished
            // document as an empty box. Block the send and say where it is.
            List<String> orphans = new List<String>();
            for (Signature_Field__c f : placed) {
                if (f.Assigned_Signer__c != null) {
                    signersWithFields.add(f.Assigned_Signer__c);
                } else {
                    String label = String.isBlank(f.Field_Label__c)
                        ? String.valueOf(f.Field_Type__c) : f.Field_Label__c;
                    orphans.add(
                        label + (f.Page_Number__c == null
                            ? '' : ' (page ' + String.valueOf(f.Page_Number__c.intValue()) + ')')
                    );
                }
            }
            if (!orphans.isEmpty()) {
                throw new AgreementException(
                    'These fields are not assigned to anyone, so nobody can fill them: '
                    + String.join(orphans, ', ')
                    + '. Assign each field to a signer, or delete it, before sending.'
                );
            }
            List<String> unassigned = new List<String>();
            for (Signer__c s : signers) {
                if (s.Status__c != 'Signed' && !signersWithFields.contains(s.Id)) {
                    unassigned.add(s.Name);
                }
            }
            if (!unassigned.isEmpty()) {
                throw new AgreementException(
                    'These signers have no fields to fill and cannot complete the agreement: '
                    + String.join(unassigned, ', ')
                    + '. Assign at least one field to each signer, or remove them, before sending.'
                );
            }
        }
        for (Signer__c s : signers) {
            // Re-sending must NOT reset signers who have ALREADY SIGNED —
            // keep their status, signed date and access token intact so the
            // certificate and audit history stay truthful.
            if (s.Status__c == 'Signed') continue;
            s.Access_Token__c = generateToken();
            s.Session_Token_Hash__c = null;
            s.Session_Bound_At__c = null;
            s.Status__c = 'Pending';
        }
        Database.update(signers, true);
        agr.Status__c = 'Sent';
        agr.Sent_Date__c = DateTime.now();
        // Generate unique Envelope ID (like DocuSign)
        if (String.isBlank(agr.Envelope_ID__c)) {
            agr.Envelope_ID__c = generateUUID();
        }
        Database.update(agr, true);
        
        // Create public URL for guest user PDF access
        try {
            DocumentService.createPublicUrlForAgreement(agreementId);
        } catch(Exception e) {
            System.debug('Public URL creation failed: ' + e.getMessage());
        }
        
        // Normalise overrides — blanks become null so default behaviour wins.
        String subj = String.isNotBlank(subjectOverride) ? subjectOverride.trim() : null;
        String msg  = String.isNotBlank(messageOverride) ? messageOverride.trim() : null;
        
        if (agr.Signing_Order__c == 'Sequential') {
            // Signers sharing the lowest pending order are a parallel group and
            // are invited TOGETHER. Previously only signers[0] was emailed, so
            // two signers given the same order meant the second one never got
            // the invitation until the first had signed.
            Decimal firstOrder = null;
            Boolean groupFound = false;
            for (Signer__c s : signers) {
                if (s.Status__c == 'Signed') continue;
                if (!groupFound) { groupFound = true; firstOrder = s.Signing_Order__c; }
                Boolean sameGroup = (s.Signing_Order__c == firstOrder)
                    || (s.Signing_Order__c == null && firstOrder == null);
                if (sameGroup) {
                    sendSignerEmail(s, agr, subj, msg);
                }
            }
        } else {
            for (Signer__c s : signers) {
                sendSignerEmail(s, agr, subj, msg);
            }
        }
        
        AuditTrailService.log(agreementId, 'Sent for Signature', UserInfo.getUserEmail(), null, null);
    }
    
    public static void generateDocumentHash(Id agreementId) {
        List<Agreement_Document__c> docs = [
            SELECT Content_Version_ID__c, S3_Document_ID__c, Storage_Tier__c, File_Size_Bytes__c
            FROM Agreement_Document__c
            WHERE Agreement__c = :agreementId
            AND Document_Type__c = 'Original'            LIMIT 1
        ];
        if (docs.isEmpty()) return;
        
        Blob pdfBytes = getDocumentBytes(docs[0]);
        if (pdfBytes == null) {
            System.debug('SignForce Hash: Could not fetch document bytes for ' + agreementId);
            return;
        }
        
        Blob docHash = Crypto.generateDigest('SHA-256', pdfBytes);
        String hashHex = EncodingUtil.convertToHex(docHash);
        
        Agreement__c agr = new Agreement__c(Id = agreementId);
        agr.Document_Hash__c = hashHex;
        Database.update(agr, true);
        
        AuditTrailService.log(agreementId, 'Document Hash Generated', 'system@signforce.com', null, 'SHA-256: ' + hashHex.substring(0, 16) + '...');
    }
    
    /**
* Verify document has not been tampered with
*/
    public static Boolean verifyDocumentHash(Id agreementId) {
        Agreement__c agr = [SELECT Document_Hash__c FROM Agreement__c WHERE Id = :agreementId];
        if (String.isBlank(agr.Document_Hash__c)) return true; // No hash stored
        
        List<Agreement_Document__c> docs = [
            SELECT Content_Version_ID__c, S3_Document_ID__c, Storage_Tier__c, File_Size_Bytes__c
            FROM Agreement_Document__c
            WHERE Agreement__c = :agreementId
            AND Document_Type__c = 'Original'            LIMIT 1
        ];
        if (docs.isEmpty()) return false;
        
        Blob pdfBytes = getDocumentBytes(docs[0]);
        if (pdfBytes == null) return false;
        
        Blob currentHash = Crypto.generateDigest('SHA-256', pdfBytes);
        String currentHashHex = EncodingUtil.convertToHex(currentHash);
        
        return currentHashHex == agr.Document_Hash__c;
    }
    
    // ═══════ FEATURE 4: Decline Notifications ═══════
    
    public static void declineAgreement(Id signerId, String reason, String ipAddress) {
        Signer__c signer = [
            SELECT Id, Agreement__c, Email__c, Name
            FROM Signer__c WHERE Id = :signerId
        ];
        signer.Status__c = 'Declined';
        signer.Decline_Reason__c = reason;
        update signer;
        
        Agreement__c agr = [
            SELECT Id, Name, Status__c, OwnerId, Owner.Email, Owner.Name
            FROM Agreement__c WHERE Id = :signer.Agreement__c
        ];
        agr.Status__c = 'Declined';
        update agr;
        
        AuditTrailService.log(signer.Agreement__c, 'Declined', signer.Email__c, ipAddress, reason);
        
        // Send decline notification to owner
        sendDeclineNotification(agr, signer, reason);
    }
    
    public static String generateUUID() {
        Blob b = Crypto.generateAesKey(128);
        String hex = EncodingUtil.convertToHex(b);
        return hex.substring(0,8) + '-' + 
            hex.substring(8,12) + '-' + 
            hex.substring(12,16) + '-' + 
            hex.substring(16,20) + '-' + 
            hex.substring(20,32);
    }
    
    // Backward-compatible 3-arg: same IP for the signer record and the audit event.
    public static void markSigned(Id signerId, String ipAddress, String userAgent) {
        markSigned(signerId, ipAddress, ipAddress, userAgent);
    }

    // signerIp → Signer record's "Using IP Address" (we store the IPv6 here);
    // auditIp  → the "Document Signed" audit-trail event (we store the IPv4 here).
    public static void markSigned(Id signerId, String signerIp, String auditIp, String userAgent) {
        Signer__c signer = [
            SELECT Id, Agreement__c, Signing_Order__c, Status__c, Role__c, Email__c, Access_Token__c
            FROM Signer__c WHERE Id = :signerId
        ];
        System.debug(LoggingLevel.INFO,
            '[SignForce IP] markSigned signerIp(v6)=[' + signerIp + '] auditIp(v4)=[' + auditIp + ']');

        // Already signed → nothing to do. Without this a second call (a
        // double-clicked Complete button, a retried request) overwrites
        // Signed_Date__c and issues a fresh Signature_Certificate_ID__c —
        // destroying the audit record of the original signature — and sends the
        // confirmation email all over again.
        if (signer.Status__c == 'Signed') return;

        signer.Status__c = 'Signed';
        signer.Signed_Date__c = DateTime.now();
        signer.Signature_Certificate_ID__c = generateUUID();
        signer.Signing_IP_Address__c = signerIp;
        signer.Signing_User_Agent__c = userAgent;
        update signer;
        AuditTrailService.log(signer.Agreement__c, 'Document Signed', signer.Email__c, auditIp, userAgent);
        checkAgreementCompletion(signer.Agreement__c);

        // "You have signed successfully" to the person who just signed — every
        // signer, including the last. It lives here rather than in the callers so
        // that guest signing and in-org signing behave identically; there is more
        // than one entry point and they used to disagree.
        //
        // Runs AFTER checkAgreementCompletion so the message knows whether anyone
        // is still outstanding. Carries no attachment and makes no callout, so it
        // is safe in this already-DML'd transaction.
        //
        // Skipped for a single-signer agreement: that person receives exactly one
        // email, the completion one, which confirms their signature AND carries the
        // documents.
        // Role__c may be null — sendForSignature invites everyone who is not a CC,
        // so a blank-role recipient really can hold a signing link. SOQL never
        // matches NULL with = or IN, so these predicates must say so explicitly or
        // that person is invisible to every count here.
        Integer signerCount = [
            SELECT COUNT() FROM Signer__c
            WHERE Agreement__c = :signer.Agreement__c
            AND (Role__c = 'Signer' OR Role__c = null)
        ];
        // Only actual signers are told "you have signed" — an Approver reaching
        // this method has approved, not signed.
        Boolean isSignerRole = String.isBlank(signer.Role__c) || signer.Role__c == 'Signer';

        // The LAST signer is skipped: completing the agreement immediately sends
        // them the "all parties have signed" email, which already confirms their
        // signature and carries the documents. A confirmation on top of it would be
        // two emails for one action, seconds apart.
        Boolean justCompleted = false;
        for (Agreement__c a : [
            SELECT Status__c FROM Agreement__c WHERE Id = :signer.Agreement__c LIMIT 1
        ]) {
            justCompleted = (a.Status__c == 'Completed');
        }

        if (signerCount > 1 && isSignerRole && !justCompleted) {
            try {
                sendSignedConfirmationEmail(signer.Agreement__c, signer.Id);
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'Signed-confirmation email failed (non-fatal): ' + e.getMessage());
            }
        }
    }
    
    
    
    // public static void declineAgreementGuest(Id signerId, String reason) {
    //     Signer__c signer = [
    //         SELECT Id, Agreement__c, Email__c, Access_Token__c
    //         FROM Signer__c
    //         WHERE Id = :signerId
    //     ];
    //     signer.Status__c = 'Declined';
    //     signer.Decline_Reason__c = reason;
    //     update signer;
    //     AuditTrailService.log(signer.Agreement__c, 'Declined', signer.Email__c, null, null);
    // }
    
    public static void declineAgreementGuest(Id signerId, String reason) {
        declineAgreement(signerId, reason, null);
    }
    
    /**
* Notify the agreement owner when a signer declines
*/
    private static void sendDeclineNotification(Agreement__c agr, Signer__c signer, String reason) {
        try {
            String headerHtml = getEmailHeader();
            String footerHtml = getEmailFooter();
            String declinedAt = DateTime.now().format('MMM dd, yyyy, h:mm a z', orgTz());
            
            String body =
                headerHtml +
                BrandingService.emailBodyOpen() +
                BrandingService.pill('danger', 'DECLINED') +
                BrandingService.heading('Document was declined') +
                BrandingService.lead(
                    BrandingService.emphasis(signer.Email__c) + ' has declined to sign ' +
                    BrandingService.emphasis(agr.Name) + '.') +
                BrandingService.metaCard(
                    new List<String>{ 'Declined by', 'When' },
                    new List<String>{ signer.Email__c, declinedAt }) +
                (String.isNotBlank(reason) ? BrandingService.noteCard('danger', 'Reason given', reason) : '') +
                BrandingService.footnote('The agreement is no longer active. No further signatures will be requested.') +
                BrandingService.emailBodyClose() +
                footerHtml;
            
            Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
            email.setToAddresses(new List<String>{ agr.Owner.Email });
            email.setSubject('Declined: "' + agr.Name + '" was declined by ' + signer.Email__c);
            String owaId = getOwaId();
            if (String.isNotBlank(owaId)) email.setOrgWideEmailAddressId(owaId);
            email.setHtmlBody(body);
            // CRUD: addressed from the Agreement__c owner, bodied from the
            // Signer__c row - both read above, both readable by guest.
            if (Schema.sObjectType.Agreement__c.isAccessible()
                && Schema.sObjectType.Signer__c.isAccessible()) {
                Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ email });
            }
        } catch(Exception e) {
            System.debug('Decline notification failed: ' + e.getMessage());
        }
    }
    
    // ═══════ FEATURE 5: Void / Correct Envelope ═══════
    
    /**
* Void an agreement - cancels all pending signatures
*/
    public static void voidAgreement(Id agreementId, String reason) {
        Agreement__c agr = [
            SELECT Id, Name, Status__c, OwnerId, Owner.Email, Owner.Name
            FROM Agreement__c WHERE Id = :agreementId        ];

        if (agr.Status__c == 'Completed') {
            throw new AgreementException('Cannot void a completed agreement.');
        }
        if (agr.Status__c == 'Voided') {
            throw new AgreementException('This agreement has already been voided.');
        }
        
        // Expire all signer tokens
        List<Signer__c> signers = [
            SELECT Id, Email__c, Status__c
            FROM Signer__c WHERE Agreement__c = :agreementId        ];
        for (Signer__c s : signers) {
            if (s.Status__c != 'Signed') {
                s.Token_Expired__c = true;
                s.Status__c = 'Voided';
            }
        }
        Database.update(signers, true);
        
        agr.Status__c = 'Voided';
        agr.Void_Reason__c = reason;
        agr.Voided_Date__c = DateTime.now();
        Database.update(agr, true);

        AuditTrailService.log(agreementId, 'Agreement Voided', UserInfo.getUserEmail(), null, reason);
        
        // Notify all signers that the agreement was voided
        sendVoidNotifications(agr, signers, reason);
    }
    
    /**
* Correct an agreement - void and create new draft to re-send
*/
    public static Id correctAgreement(Id agreementId, String reason) {
        Agreement__c oldAgr = [
            SELECT Id, Name, Agreement_Type__c, Signing_Order__c, Message_to_Signers__c, Expiry_Date__c
            FROM Agreement__c WHERE Id = :agreementId        ];
        
        // Void the old one
        voidAgreement(agreementId, 'Corrected: ' + reason);
        
        // Create a new draft copy
        Agreement__c newAgr = new Agreement__c();
        newAgr.Name = oldAgr.Name + ' (Corrected)';
        newAgr.Agreement_Type__c = oldAgr.Agreement_Type__c;
        newAgr.Signing_Order__c = oldAgr.Signing_Order__c;
        newAgr.Message_to_Signers__c = oldAgr.Message_to_Signers__c;
        newAgr.Expiry_Date__c = oldAgr.Expiry_Date__c;
        newAgr.Status__c = 'Draft';
        newAgr.Storage_Location__c = 'Salesforce';
        Database.insert(newAgr, true);
        
        AuditTrailService.log(newAgr.Id, 'Agreement Created (Corrected from ' + agreementId + ')', UserInfo.getUserEmail(), null, null);
        return newAgr.Id;
    }
    
    /**
* Notify signers that agreement was voided
*/
    private static void sendVoidNotifications(Agreement__c agr, List<Signer__c> signers, String reason) {
        try {
            String headerHtml = getEmailHeader();
            String footerHtml = getEmailFooter();
            List<Messaging.SingleEmailMessage> emails = new List<Messaging.SingleEmailMessage>();
            
            String cancelledAt = DateTime.now().format('MMM dd, yyyy, h:mm a z', orgTz());
            
            for (Signer__c s : signers) {
                String body =
                    headerHtml +
                    BrandingService.emailBodyOpen() +
                    BrandingService.pill('neutral', 'CANCELLED') +
                    BrandingService.heading('This agreement has been cancelled') +
                    BrandingService.lead(
                        'The agreement ' + BrandingService.emphasis(agr.Name) +
                        ' has been cancelled by the sender.') +
                    BrandingService.paragraph('No further action is required from you.') +
                    BrandingService.metaCard(
                        new List<String>{ 'Cancelled on' },
                        new List<String>{ cancelledAt }) +
                    (String.isNotBlank(reason) ? BrandingService.noteCard('neutral', 'Reason', reason) : '') +
                    BrandingService.footnote('You can discard any earlier signing request for this document.') +
                    BrandingService.emailBodyClose() +
                    footerHtml;
                
                Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
                email.setToAddresses(new List<String>{ s.Email__c });
                email.setSubject('Cancelled: "' + agr.Name + '"');
                String owaId = getOwaId();
                if (String.isNotBlank(owaId)) email.setOrgWideEmailAddressId(owaId);
                email.setHtmlBody(body);
                emails.add(email);
            }
            // CRUD: recipients come from the Signer__c rows, the subject from
            // the Agreement__c row - both read above.
            if (!emails.isEmpty()
                && Schema.sObjectType.Signer__c.isAccessible()
                && Schema.sObjectType.Agreement__c.isAccessible()) {
                Messaging.sendEmail(emails);
            }
        } catch(Exception e) {
            System.debug('Void notifications failed: ' + e.getMessage());
        }
    }
    
    // ═══════ FEATURE 6: Reminder Emails ═══════
    
    /**
* Send reminder to a specific signer
*/
    public static void sendReminderEmail(Id signerId) {
        Signer__c signer = [
            SELECT Id, Email__c, Status__c, Access_Token__c, Agreement__c,
            Token_Created_Date__c, Token_Expired__c
            FROM Signer__c WHERE Id = :signerId        ];

        if (signer.Status__c == 'Signed' || signer.Status__c == 'Declined') {
            throw new AgreementException('Cannot send reminder to this signer.');
        }

        // A signer only gets an access token when the agreement is SENT. A
        // reminder from a Draft would email a link with token=null, which lands
        // on "Invalid signing link".
        if (String.isBlank(signer.Access_Token__c)) {
            throw new AgreementException(
                'This agreement has not been sent yet — send it for signature first, then remind.');
        }

        // Check if token expired, regenerate if needed
        if (signer.Token_Created_Date__c != null) {
            DateTime expiryTime = signer.Token_Created_Date__c.addHours(TOKEN_EXPIRY_HOURS);
            if (DateTime.now() > expiryTime || signer.Token_Expired__c == true) {
                signer.Access_Token__c = generateToken();
                signer.Session_Token_Hash__c = null;
                signer.Session_Bound_At__c = null;
                signer.Token_Created_Date__c = DateTime.now();
                signer.Token_View_Count__c = 0;
                signer.Token_Expired__c = false;
                // The queried record carries Agreement__c, a non-reparentable
                // master-detail. A USER_MODE update refuses any payload containing
                // that field for a non-admin (CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY
                // on Agreement__c), even when its value is unchanged — so the token
                // rotation is written through a minimal record carrying only the
                // fields this method actually changes.
                Signer__c tokenUpdate = new Signer__c(Id = signer.Id);
                tokenUpdate.Access_Token__c = signer.Access_Token__c;
                tokenUpdate.Session_Token_Hash__c = null;
                tokenUpdate.Session_Bound_At__c = null;
                tokenUpdate.Token_Created_Date__c = signer.Token_Created_Date__c;
                tokenUpdate.Token_View_Count__c = 0;
                tokenUpdate.Token_Expired__c = false;
                Database.update(tokenUpdate, true);
            }
        }

        Agreement__c agr = [
            SELECT Id, Name, Message_to_Signers__c, Sent_Date__c
            FROM Agreement__c WHERE Id = :signer.Agreement__c        ];
        
        sendReminderEmailToSigner(signer, agr);
        
        // Update reminder date on agreement
        Agreement__c agrUpdate = new Agreement__c(Id = agr.Id);
        agrUpdate.Last_Reminder_Sent__c = DateTime.now();
        Database.update(agrUpdate, true);

        AuditTrailService.log(agr.Id, 'Reminder Sent', signer.Email__c, null, null);
    }
    
    /**
* Send reminders to ALL pending signers on an agreement
*/
    public static void sendBulkReminders(Id agreementId) {
        List<Signer__c> pendingSigners = [
            SELECT Id, Email__c, Status__c, Access_Token__c, 
            Token_Created_Date__c, Token_Expired__c
            FROM Signer__c
            WHERE Agreement__c = :agreementId
            AND Status__c IN ('Pending', 'Sent')
        ];
        
        Agreement__c agr = [
            SELECT Id, Name, Message_to_Signers__c, Sent_Date__c
            FROM Agreement__c WHERE Id = :agreementId
        ];
        
        // Checked BEFORE any reminder goes out. The loop below rotates expired
        // tokens and mails the new link, but the rotation is only persisted by the
        // update after the loop - so a context that cannot write Signer__c would
        // send every signer a link whose token was never saved. Failing here is the
        // only safe order. This is an internal admin action; the running user has
        // edit on Signer__c, so the throw is defensive.
        if (!Schema.sObjectType.Signer__c.isUpdateable()) {
            throw new AgreementException('Insufficient access to update Signer records.');
        }

        for (Signer__c s : pendingSigners) {
            // Regenerate token if expired
            if (s.Token_Created_Date__c != null) {
                DateTime expiryTime = s.Token_Created_Date__c.addHours(TOKEN_EXPIRY_HOURS);
                if (DateTime.now() > expiryTime || s.Token_Expired__c == true) {
                    s.Access_Token__c = generateToken();
                    s.Session_Token_Hash__c = null;
                    s.Session_Bound_At__c = null;
                    s.Token_Created_Date__c = DateTime.now();
                    s.Token_View_Count__c = 0;
                    s.Token_Expired__c = false;
                }
            }
            sendReminderEmailToSigner(s, agr);
        }
        // Positive branch: the scanner reads the check on the flow into the DML,
        // not the throw above. Always true by the time we are here.
        if (Schema.sObjectType.Signer__c.isUpdateable()) {
            update pendingSigners;
        }
        
        Agreement__c agrUpdate = new Agreement__c(Id = agreementId);
        agrUpdate.Last_Reminder_Sent__c = DateTime.now();
        // Skip rather than throw: this is a cosmetic "last reminded" timestamp and
        // the reminders have already gone out. Losing it must not fail the action.
        if (Schema.sObjectType.Agreement__c.isUpdateable()) {
            update agrUpdate;
        }
        
        AuditTrailService.log(agreementId, 'Bulk Reminder Sent', UserInfo.getUserEmail(), null,
                              pendingSigners.size() + ' signers reminded');
    }
    
    private static void sendReminderEmailToSigner(Signer__c signer, Agreement__c agr) {
        String baseUrl = SignForceConfigService.getSigningSiteBaseUrl();
        String signingUrl = baseUrl + '/signature?token=' + signer.Access_Token__c;
        String headerHtml = getEmailHeader();
        String footerHtml = getEmailFooter();
        
        // Days pending
        Integer daysPending = 0;
        if (agr.Sent_Date__c != null) {
            Long diffMs = DateTime.now().getTime() - agr.Sent_Date__c.getTime();
            daysPending = (Integer) (diffMs / (1000L * 60L * 60L * 24L));
        }
        String daysText = (daysPending <= 0) ? 'today'
            : (daysPending == 1 ? '1 day ago'
               : daysPending + ' days ago');
                   
                   String body =
                   headerHtml +
                   BrandingService.emailBodyOpen() +
                   BrandingService.pill('warning', 'REMINDER') +
                   BrandingService.heading('Your signature is still needed') +
                   BrandingService.lead(
                       'You have a pending document waiting for your signature: ' +
                       BrandingService.emphasis(agr.Name) + '.') +
                   BrandingService.infoCard('warning', 'Pending since', 'Originally sent ' + daysText) +
                   (String.isNotBlank(agr.Message_to_Signers__c)
                       ? BrandingService.noteCard('warning', 'Message from sender', agr.Message_to_Signers__c) : '') +
                   BrandingService.cta(signingUrl, 'Sign now →', 'warning') +
                   BrandingService.fallbackLink(signingUrl) +
                   BrandingService.footnote('This is a reminder. The original request was sent earlier and this link is unique to you.') +
                   BrandingService.emailBodyClose() +
                   footerHtml;
        
        Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
        email.setToAddresses(new List<String>{ signer.Email__c });
        email.setSubject('Reminder: Please sign "' + agr.Name + '"');
        String owaId = getOwaId();
        if (String.isNotBlank(owaId)) email.setOrgWideEmailAddressId(owaId);
        email.setHtmlBody(body);
        // CRUD: built from the Signer__c token/address and the Agreement__c
        // name and message, both read by the callers above.
        if (Schema.sObjectType.Signer__c.isAccessible()
            && Schema.sObjectType.Agreement__c.isAccessible()) {
            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ email });
        }
    }
    
    public static void resendSignerEmail(Id signerId) {
        Signer__c signer = [
            SELECT Id, Email__c, Agreement__c, Access_Token__c, Status__c,
            Token_Created_Date__c
            FROM Signer__c WHERE Id = :signerId        ];

        // Regenerate token (fresh 48h window)
        signer.Access_Token__c = generateToken();
        signer.Session_Token_Hash__c = null;
        signer.Session_Bound_At__c = null;
        signer.Token_Created_Date__c = DateTime.now();
        signer.Token_View_Count__c = 0;
        signer.Token_Expired__c = false;
        // The queried record carries Agreement__c, a non-reparentable
        // master-detail. A USER_MODE update refuses any payload containing
        // that field for a non-admin (CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY
        // on Agreement__c), even when its value is unchanged — so the token
        // rotation is written through a minimal record carrying only the
        // fields this method actually changes.
        Signer__c tokenUpdate = new Signer__c(Id = signer.Id);
        tokenUpdate.Access_Token__c = signer.Access_Token__c;
        tokenUpdate.Session_Token_Hash__c = null;
        tokenUpdate.Session_Bound_At__c = null;
        tokenUpdate.Token_Created_Date__c = signer.Token_Created_Date__c;
        tokenUpdate.Token_View_Count__c = 0;
        tokenUpdate.Token_Expired__c = false;
        // A remote link must re-prove identity: startInPersonSigning pre-clears
        // the OTP gate for its face-to-face session, and without this reset an
        // abandoned in-person attempt would let the emailed link skip OTP too.
        tokenUpdate.OTP_Verified__c = false;
        Database.update(tokenUpdate, true);

        Agreement__c agr = [
            SELECT Id, Name, Message_to_Signers__c, OwnerId
            FROM Agreement__c WHERE Id = :signer.Agreement__c        ];
        sendSignerEmail(signer, agr);
    }
    
    private static void checkAgreementCompletion(Id agreementId) {
        List<Signer__c> signers = [
            SELECT Id, Status__c, Role__c, Signing_Order__c, Email__c, Access_Token__c
            FROM Signer__c
            WHERE Agreement__c = :agreementId
            AND (Role__c = 'Signer' OR Role__c = null)
            ORDER BY Signing_Order__c ASC NULLS LAST
        ];
        Agreement__c agr = [
            SELECT Id, Signing_Order__c, Status__c, Name,
            Message_to_Signers__c, OwnerId, Owner.Email, Owner.Name
            FROM Agreement__c WHERE Id = :agreementId
        ];
        Boolean allSigned = true;
        // Sequential advance, group-aware: everyone at the lowest unsigned order
        // is in play together. Only 'Pending' members get an email here — group
        // members invited at send time are already 'Sent', so one member signing
        // does not spam the rest of the group with duplicate invitations.
        Boolean groupFound = false;
        Decimal activeOrder = null;
        for (Signer__c s : signers) {
            if (s.Status__c == 'Signed') continue;
            allSigned = false;
            if (agr.Signing_Order__c != 'Sequential') break;
            if (!groupFound) { groupFound = true; activeOrder = s.Signing_Order__c; }
            Boolean sameGroup = (s.Signing_Order__c == activeOrder)
                || (s.Signing_Order__c == null && activeOrder == null);
            if (sameGroup && s.Status__c == 'Pending') {
                sendSignerEmail(s, agr);
            }
        }
        if (allSigned) {
            agr.Status__c = 'Completed';
            agr.Completed_Date__c = DateTime.now();
            update agr;

            // BUG-061: CC recipients (Role__c='CC') are created 'Pending' and were
            // never advanced, so they showed "Pending" forever after completion.
            // Now that all SIGNERS have signed, move any still-open CC rows to a
            // terminal status. Signer__c.Status__c is a RESTRICTED picklist whose
            // values are: Pending, Sent, Viewed, Signed, Declined, Voided — there
            // is no 'Completed'/'Notified' value, so we reuse the same terminal
            // value signers receive on completion ('Signed'). The allSigned gate
            // above filters Role__c='Signer' only, so CCs never block completion
            // and this status change cannot affect completion semantics.
            List<Signer__c> ccRows = [
                SELECT Id, Status__c
                FROM Signer__c
                WHERE Agreement__c = :agreementId
                AND Role__c = 'CC'
                AND Status__c != 'Signed'
                AND Status__c != 'Declined'
                AND Status__c != 'Voided'
            ];
            if (!ccRows.isEmpty()) {
                for (Signer__c cc : ccRows) {
                    cc.Status__c = 'Signed';
                }
                update ccRows;
            }

            // Completion is reached automatically when the last signer signs
            // (often a guest signing session), so there is no initiating
            // Salesforce user — use a safe system literal rather than the
            // (guest) running user's email.
            AuditTrailService.log(agreementId, 'Agreement Completed', 'system@signforce.com', null, null);
        }
    }
    
    public static void sendCompletionEmailsPublic(Id agreementId) {
        Agreement__c agr = [
            SELECT Id, Name, Status__c, Signing_Order__c,
            Message_to_Signers__c, OwnerId, Owner.Email, Owner.Name
            FROM Agreement__c WHERE Id = :agreementId
        ];
        // BUG-030 FIX: completion notification should reach ALL parties on the
        // agreement (Signer, Approver, CC). Previously only Role__c='Signer'
        // got the email so Approvers and CCs never knew the deal closed.
        // Note: the role filter in checkAgreementCompletion() is intentionally
        // left as 'Signer'-only because completion semantics require all
        // signers to sign; approvers/CCs aren't expected to sign anything.
        List<Signer__c> signers = [
            SELECT Id, Status__c, Role__c, Signing_Order__c, Email__c, Access_Token__c
            FROM Signer__c
            WHERE Agreement__c = :agreementId
            AND (Role__c IN ('Signer', 'Approver', 'CC') OR Role__c = null)
            ORDER BY Signing_Order__c ASC NULLS LAST
        ];
        sendCompletionEmails(agr, signers);
    }

    /**
     * "You have signed successfully" — sent to a signer immediately after THEY
     * sign, for every signer including the last one.
     *
     * Carries NO attachment by design. Documents travel only with the final
     * completion email, once every party has signed; sending a part-signed PDF at
     * each step puts an incomplete copy of a legal document into circulation and
     * leaves recipients unsure which version is authoritative.
     *
     * Sent only while signatures are still outstanding. The person who signs LAST
     * does not get one — completing the agreement sends them the "all parties have
     * signed" email, which confirms their signature and carries the documents in a
     * single message. A single-signer agreement is the same case: one email only.
     */
    public static void sendSignedConfirmationEmail(Id agreementId, Id signerId) {
        Agreement__c agr = [SELECT Id, Name FROM Agreement__c WHERE Id = :agreementId];
        Signer__c signer = [SELECT Id, Name, Email__c FROM Signer__c WHERE Id = :signerId];
        if (String.isBlank(signer.Email__c)) return;

        String nextStep = 'The next signer has been notified. '
            + 'You will receive the completed document once everyone has signed.';

        Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
        mail.setToAddresses(new List<String>{ signer.Email__c });
        mail.setSubject('You have signed "' + agr.Name + '"');
        mail.setHtmlBody(
            getEmailHeader()
            + BrandingService.emailBodyOpen()
            + BrandingService.pill('success', 'SIGNED')
            + BrandingService.heading('You have signed successfully')
            + BrandingService.lead('Hi ' + BrandingService.emphasis(signer.Name)
                + ', you have successfully signed ' + BrandingService.emphasis(agr.Name) + '.')
            + BrandingService.paragraph(nextStep)
            + BrandingService.footnote('Sent via ' + BrandingService.brandName())
            + BrandingService.emailBodyClose()
            + getEmailFooter()
        );
        String owaId = getOwaId();
        if (String.isNotBlank(owaId)) mail.setOrgWideEmailAddressId(owaId);

        // CRUD: built from the Agreement__c and Signer__c rows read above.
        // Guest holds read on both, so the branch is always taken.
        if (Schema.sObjectType.Signer__c.isAccessible()
            && Schema.sObjectType.Agreement__c.isAccessible()) {
            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ mail });
        }
        AuditTrailService.log(agreementId, 'Signed Confirmation Emailed', signer.Email__c, null, null);
    }
    
    private static void sendCompletionEmails(Agreement__c agr, List<Signer__c> signers) {
        List<Messaging.SingleEmailMessage> emails = new List<Messaging.SingleEmailMessage>();
        
        String headerHtml = getEmailHeader();
        String footerHtml = getEmailFooter();
        
        String completedOn = DateTime.now().format('MMM dd, yyyy, h:mm a z', orgTz());
        
        // De-dupe recipients: a person who is BOTH the owner and a signer
        // (e.g. self-sign / sender signs their own doc) must not receive two
        // completion emails — the duplicate "Completed:" pair reported by users.
        Set<String> signerEmailSet = new Set<String>();
        Integer signerRoleCount = 0;
        for (Signer__c sig : signers) {
            if (String.isNotBlank(sig.Email__c)) signerEmailSet.add(sig.Email__c.trim().toLowerCase());
            // Same population checkAgreementCompletion gates on — including the
            // blank role it also accepts — so soleSigner is computed over exactly
            // the people who had to sign and were sent a confirmation.
            if (String.isBlank(sig.Role__c) || sig.Role__c == 'Signer') signerRoleCount++;
        }
        // A single-signer agreement produces exactly ONE email in total: the one
        // below, to that signer, carrying the documents. There is no round of
        // "you have signed" confirmations to summarise and nobody else is waiting,
        // so an "all parties have signed" announcement to the sender would just be
        // a second copy of news they can already see on the record.
        Boolean soleSigner = (signerRoleCount <= 1);

        Set<String> sentTo = new Set<String>();
        String owaId = getOwaId();
        String ownerAddr = (agr.Owner != null) ? agr.Owner.Email : null;
        Boolean ownerIsSigner = String.isNotBlank(ownerAddr)
            && signerEmailSet.contains(ownerAddr.trim().toLowerCase());

        // ── Owner: "all parties signed" — skipped when the owner is also a signer
        //    (they get the per-signer email with the same Stamped + Certificate
        //    attachments), and skipped entirely for a sole-signer agreement. ──
        if (String.isNotBlank(ownerAddr) && !ownerIsSigner && !soleSigner) {
        List<String> signerEmails = new List<String>();
        for (Signer__c sig : signers) {
            if (String.isNotBlank(sig.Email__c)) signerEmails.add(sig.Email__c);
        }
        String ownerBody =
            headerHtml +
            BrandingService.emailBodyOpen() +
            BrandingService.pill('success', 'COMPLETED') +
            BrandingService.heading('All parties have signed') +
            BrandingService.lead(
                BrandingService.emphasis(agr.Name) +
                ' has been signed by everyone. The signed document and audit certificate are included with this email.') +
            BrandingService.metaCard(
                new List<String>{ 'Completed on', 'Signers' },
                new List<String>{ completedOn, signers.size() + ' parties' }) +
            BrandingService.panelCard('Signed by', BrandingService.bulletList('successDot', signerEmails)) +
            BrandingService.footnote('Keep this email for your records. The signed PDF is legally binding.') +
            BrandingService.emailBodyClose() +
            footerHtml;
        
        Messaging.SingleEmailMessage ownerEmail = new Messaging.SingleEmailMessage();
        ownerEmail.setToAddresses(new List<String>{ ownerAddr });
        ownerEmail.setSubject('Completed: "' + agr.Name + '" has been signed by all parties');
        if (String.isNotBlank(owaId)) ownerEmail.setOrgWideEmailAddressId(owaId);
        ownerEmail.setHtmlBody(ownerBody);
        emails.add(ownerEmail);
        }
        
        // ── Per-signer: role-aware completion notification ────────────
        // BUG-030 FIX: Approvers and CCs now receive completion emails too,
        // but the body/subject must NOT say "You have signed" for them.
        for (Signer__c s : signers) {
            // Skip blank addresses and anyone already emailed (owner overlap or
            // the same person listed as a signer more than once).
            if (String.isBlank(s.Email__c)) continue;
            String sKey = s.Email__c.trim().toLowerCase();
            if (sentTo.contains(sKey)) continue;
            sentTo.add(sKey);
            String role = String.isBlank(s.Role__c) ? 'Signer' : s.Role__c;
            Boolean isSigner = (role == 'Signer');
            Boolean isApprover = (role == 'Approver');
            // Anything else (CC, etc.) → treated as informational copy
            
            String pillLabel;
            String headlineText;
            String bodyText;
            String subject;
            String dateLabel;
            if (isSigner && soleSigner) {
                // The only email this person receives: it confirms their signature
                // and carries the documents in one go.
                pillLabel    = 'SIGNED';
                headlineText = 'You have signed successfully';
                bodyText     = 'Thank you for signing ' + BrandingService.emphasis(agr.Name)
                    + '. A copy of the fully executed document is attached for your records.';
                subject      = 'Completed: You have signed "' + agr.Name + '"';
                dateLabel    = 'Signed on';
            } else if (isSigner) {
                // Every signer already received a "you have signed successfully"
                // confirmation the moment they signed, so this email announces that
                // EVERYONE is done and delivers the documents.
                pillLabel    = 'COMPLETED';
                headlineText = 'All parties have signed';
                bodyText     = BrandingService.emphasis(agr.Name)
                    + ' has been signed by everyone. The signed document and audit certificate are attached for your records.';
                subject      = 'Completed: "' + agr.Name + '" has been signed by all parties';
                dateLabel    = 'Completed on';
            } else if (isApprover) {
                pillLabel    = 'COMPLETED';
                headlineText = 'Agreement completed';
                bodyText     = 'The agreement ' + BrandingService.emphasis(agr.Name)
                    + ' has been fully executed by all signers. As an approver, a copy of the signed document is attached for your records.';
                subject      = 'Completed: "' + agr.Name + '" has been signed';
                dateLabel    = 'Completed on';
            } else {
                // CC or any other informational role
                pillLabel    = 'COMPLETED';
                headlineText = 'Agreement completed';
                bodyText     = 'You are copied on the agreement ' + BrandingService.emphasis(agr.Name)
                    + ', which has been fully executed by all signers. A copy of the signed document is attached for your reference.';
                subject      = 'Completed (cc): "' + agr.Name + '"';
                dateLabel    = 'Completed on';
            }
            
            String signerBody =
                headerHtml +
                BrandingService.emailBodyOpen() +
                BrandingService.pill('success', pillLabel) +
                BrandingService.heading(headlineText) +
                BrandingService.lead(bodyText) +
                BrandingService.metaCard(
                    new List<String>{ dateLabel },
                    new List<String>{ completedOn }) +
                BrandingService.footnote('Keep this email for your records. The signed PDF is legally binding.') +
                BrandingService.emailBodyClose() +
                // The download-links row is injected at the <!--SF_BODY_END--> sentinel
                // that getEmailFooter() emits, so the injected <tr> lands inside the
                // outer table (Gmail drops <tr>s that fall outside </table>).
                footerHtml;
            
            Messaging.SingleEmailMessage signerEmail = new Messaging.SingleEmailMessage();
            signerEmail.setToAddresses(new List<String>{ s.Email__c });
            signerEmail.setSubject(subject);
            if (String.isNotBlank(owaId)) signerEmail.setOrgWideEmailAddressId(owaId);
            signerEmail.setHtmlBody(signerBody);
            emails.add(signerEmail);
        }
        
        if (!emails.isEmpty()) {
            
            // ─── HYBRID ATTACHMENT STRATEGY ─────────────────────────────────
            // Salesforce single-email API caps total attachment size at ~10MB.
            // Above that, Salesforce silently converts attachments to "click to
            // download" HTML stubs — a poor user experience.
            //
            // Strategy:
            //   1. Try to inline-attach Stamped (preferred) + Cert
            //   2. Track running total; if next attachment would exceed 9MB cap,
            //      switch it to a presigned S3 download link in the email body
            //   3. Original is NOT attached when Stamped exists (redundant — the
            //      stamped PDF contains everything from the original plus signatures)
            //
            // Attachment metadata: we collect (filename, blob, optional fallback URL)
            // pairs first, then decide inline-vs-link based on cumulative size.
            
            List<Messaging.EmailFileAttachment> inlineAttachments = new List<Messaging.EmailFileAttachment>();
            List<Map<String, String>> downloadLinks = new List<Map<String, String>>();
            Long runningTotal = 0L;
            
            // ── 1. Stamped Signed Document (preferred primary attachment) ──
            // Pick the latest valid Stamped record (has S3 or CV content).
            // If duplicate Stamped records exist due to Guest User not having
            // delete permission, this picks the most recent valid one.
            List<Agreement_Document__c> stampedDocs = [
                SELECT Id, Name, Content_Version_ID__c, S3_Document_ID__c, S3_Preview_URL__c, Storage_Tier__c, File_Size_Bytes__c,
                    Storage_Type__c, Cloud_File_Id__c, Cloud_Provider__c
                FROM Agreement_Document__c
                WHERE Agreement__c = :agr.Id
                AND Document_Type__c = 'Stamped'
                AND (S3_Document_ID__c != null OR Content_Version_ID__c != null
                     OR (Storage_Type__c = 'Cloud' AND Cloud_File_Id__c != null))
                ORDER BY CreatedDate DESC
                LIMIT 1
            ];
            
            if (!stampedDocs.isEmpty()) {
                System.debug('Email: Found Stamped record: S3=' + stampedDocs[0].S3_Document_ID__c 
                             + ', CV=' + stampedDocs[0].Content_Version_ID__c);
            } else {
                System.debug('Email: No valid Stamped record found, will fallback to Original');
            }
            Boolean stampedAttached = false;
            if (!stampedDocs.isEmpty()) {
                Agreement_Document__c d = stampedDocs[0];
                String title = sanitizeFileName(
                    String.isNotBlank(d.Name) ? d.Name : (agr.Name + ' - Signed Document')
                );
                AttachmentResult ar = tryAttachOrLink(d, title, runningTotal);
                if (ar != null) {
                    if (ar.attachment != null) {
                        inlineAttachments.add(ar.attachment);
                        runningTotal += ar.size;
                        System.debug('Email: inline-attached Stamped (' + ar.size + ' bytes)');
                    } else if (String.isNotBlank(ar.downloadUrl)) {
                        downloadLinks.add(new Map<String, String>{
                            'label' => title + ' (Signed Document)',
                                'url'   => ar.downloadUrl
                                });
                        System.debug('Email: Stamped too large — added download link');
                    }
                    stampedAttached = (ar.attachment != null) || String.isNotBlank(ar.downloadUrl);
                }
            }
            
            // ── Fallback: Original if Stamped genuinely missing ──
            if (!stampedAttached) {
                List<Agreement_Document__c> origDocs = [
                    SELECT Id, Name, Content_Version_ID__c, S3_Document_ID__c, S3_Preview_URL__c, Storage_Tier__c, File_Size_Bytes__c,
                        Storage_Type__c, Cloud_File_Id__c, Cloud_Provider__c
                    FROM Agreement_Document__c
                    WHERE Agreement__c = :agr.Id
                    AND Document_Type__c = 'Original'
                    ORDER BY CreatedDate DESC
                    LIMIT 1
                ];
                if (!origDocs.isEmpty()) {
                    Agreement_Document__c d = origDocs[0];
                    String title = sanitizeFileName(
                        String.isNotBlank(d.Name) ? d.Name : agr.Name
                    );
                    AttachmentResult ar = tryAttachOrLink(d, title, runningTotal);
                    if (ar != null) {
                        if (ar.attachment != null) {
                            inlineAttachments.add(ar.attachment);
                            runningTotal += ar.size;
                            System.debug('Email: inline-attached Original fallback');
                        } else if (String.isNotBlank(ar.downloadUrl)) {
                            downloadLinks.add(new Map<String, String>{
                                'label' => title,
                                    'url'   => ar.downloadUrl
                                    });
                        }
                    }
                }
            }
            
            // ── 2. Signing Certificate ──
            List<Agreement_Document__c> certDocs = [
                SELECT Id, Name, Content_Version_ID__c, S3_Document_ID__c, S3_Preview_URL__c, Storage_Tier__c, File_Size_Bytes__c,
                    Storage_Type__c, Cloud_File_Id__c, Cloud_Provider__c
                FROM Agreement_Document__c
                WHERE Agreement__c = :agr.Id
                AND Document_Type__c = 'Signed'
                ORDER BY CreatedDate DESC
                LIMIT 1
            ];
            if (!certDocs.isEmpty()) {
                Agreement_Document__c d = certDocs[0];
                String title = sanitizeFileName(
                    String.isNotBlank(d.Name) && !d.Name.startsWith('a0')
                    ? d.Name
                    : (agr.Name + ' - Signing Certificate')
                );
                AttachmentResult ar = tryAttachOrLink(d, title, runningTotal);
                if (ar != null) {
                    if (ar.attachment != null) {
                        inlineAttachments.add(ar.attachment);
                        runningTotal += ar.size;
                        System.debug('Email: inline-attached Certificate');
                    } else if (String.isNotBlank(ar.downloadUrl)) {
                        downloadLinks.add(new Map<String, String>{
                            'label' => title + ' (Audit Certificate)',
                                'url'   => ar.downloadUrl
                                });
                    }
                }
            }
            
            // ── Inject download-links section into HTML body if any ──
            if (!downloadLinks.isEmpty()) {
                String linksHtml = buildDownloadLinksHtml(downloadLinks);
                for (Messaging.SingleEmailMessage email : emails) {
                    String body = email.getHtmlBody();
                    if (body != null) {
                        // Insert at SF_BODY_END sentinel (preferred), else just before </body>.
                        Integer idx = body.indexOf('<!--SF_BODY_END-->');
                        if (idx < 0) idx = body.toLowerCase().indexOf('</body>');
                        if (idx > 0) {
                            email.setHtmlBody(body.substring(0, idx) + linksHtml + body.substring(idx));
                        } else {
                            email.setHtmlBody(body + linksHtml);
                        }
                    } else {
                        email.setHtmlBody(linksHtml);
                    }
                }
            }
            
            if (!inlineAttachments.isEmpty()) {
                for (Messaging.SingleEmailMessage email : emails) {
                    email.setFileAttachments(inlineAttachments);
                }
            }
            
            System.debug('SignForce Email: sending ' + emails.size()
                         + ' emails, ' + inlineAttachments.size() + ' inline + '
                         + downloadLinks.size() + ' links, total inline bytes ' + runningTotal);

            // Sent per recipient, not all-or-none. Messaging.sendEmail defaults to
            // all-or-none, so a SINGLE unusable address rejects the entire batch
            // and nobody learns the agreement completed. A CC address is the most
            // likely offender: unlike a signer's, it is typed once and never proved
            // by anyone opening a signing link, so a typo goes unnoticed until the
            // one email that would have used it. Every caller of this method wraps
            // it in a catch that only writes a debug line, so that rejection left
            // no trace anywhere an admin could see it — hence the audit entry
            // below, recorded against the address that actually failed.
            // CRUD: the recipients come from the Agreement__c owner and the
            // Signer__c rows read above; their read access gates the send. Both
            // are readable by guest, so the branch is always taken and the
            // per-recipient reporting below is unchanged.
            List<Messaging.SendEmailResult> results = new List<Messaging.SendEmailResult>();
            if (Schema.sObjectType.Agreement__c.isAccessible()
                && Schema.sObjectType.Signer__c.isAccessible()) {
                results = Messaging.sendEmail(emails, false);
            }
            Integer failedCount = 0;
            for (Integer i = 0; i < results.size(); i++) {
                if (results[i].isSuccess()) continue;
                failedCount++;
                List<String> to = emails[i].getToAddresses();
                String addr = (to != null && !to.isEmpty()) ? to[0] : '(unknown recipient)';
                String reason = '';
                for (Messaging.SendEmailError err : results[i].getErrors()) {
                    reason += (String.isBlank(reason) ? '' : '; ') + err.getMessage();
                }
                if (String.isBlank(reason)) reason = 'The address was rejected without a stated reason.';
                System.debug(LoggingLevel.ERROR,
                    'SignForce Email: completion email rejected for ' + addr + ' — ' + reason);
                AuditTrailService.log(agr.Id, 'Completion Email Failed', addr, null, null, reason);
            }
            // Nothing got through at all — that is a configuration fault rather
            // than one bad address, and the callers that show errors to an admin
            // (regenerateStampedAndResend) have to keep seeing it.
            if (failedCount > 0 && failedCount == results.size()) {
                throw new AgreementException(
                    'The completion emails could not be sent. All ' + failedCount
                    + ' recipient(s) were rejected. See the agreement audit trail for details.'
                );
            }
        }
    }
    
    /**
* Decide for ONE document: should we inline-attach (returns AttachmentResult.attachment),
* or send a download link (returns AttachmentResult.downloadUrl)?
*
*   - Skips entirely if document has no fetchable bytes/URL.
*   - For S3 docs > MAX_SINGLE_ATTACHMENT_BYTES, never inline (skip the bytes
*     fetch, just return the presigned URL).
*   - For docs that fit alone but would push runningTotal over MAX_TOTAL, link.
*   - Otherwise inline.
*/
    private class AttachmentResult {
        public Messaging.EmailFileAttachment attachment;
        public Long size;
        public String downloadUrl;
    }
    
    /**
     * Pull a cloud-stored document's bytes back through the Lambda proxy so they
     * can be attached to the completion email. Only ever called for documents that
     * are already known (or believed) to be small enough to attach — a whole large
     * file would blow the Apex heap, which is why the caller gates on size first.
     *
     * Best-effort: returns null on any failure (including "uncommitted work
     * pending" when the caller's transaction has already done DML), and the caller
     * then falls back to sending a download link.
     */
    private static Blob fetchCloudBytes(Agreement_Document__c doc) {
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint(SignForceConfigService.getLambdaEndpoint());
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setTimeout(120000);
            req.setBody(JSON.serialize(new Map<String, Object>{
                'action'     => 'downloadFromCloud',
                'orgId'      => UserInfo.getOrganizationId(),
                'provider'   => doc.Cloud_Provider__c,
                'fileId'     => doc.Cloud_File_Id__c,
                'rangeStart' => 0,
                'rangeLen'   => (Integer) MAX_SINGLE_ATTACHMENT_BYTES
            }));
            HttpResponse res = new Http().send(req);
            if (res.getStatusCode() != 200) {
                System.debug(LoggingLevel.WARN, 'fetchCloudBytes: HTTP ' + res.getStatusCode());
                return null;
            }
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            if (body.get('success') != true) {
                System.debug(LoggingLevel.WARN, 'fetchCloudBytes: ' + body.get('message'));
                return null;
            }
            // The proxy reports the FULL file size; anything past one attachment's
            // worth means this document belongs in a link, not an attachment.
            Object rawSize = body.get('size');
            if (rawSize != null && Long.valueOf(String.valueOf(rawSize)) > MAX_SINGLE_ATTACHMENT_BYTES) {
                return null;
            }
            String b64 = (String) body.get('pdfBase64');
            if (String.isBlank(b64)) return null;
            return EncodingUtil.base64Decode(b64);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'fetchCloudBytes failed: ' + e.getMessage());
            return null;
        }
    }

    private static AttachmentResult tryAttachOrLink(
        Agreement_Document__c doc,
        String fileName,
        Long runningTotal
    ) {
        if (doc == null) return null;
        AttachmentResult result = new AttachmentResult();

        // Cloud-stored docs. Now that a connected provider takes documents of ANY
        // size, a small one must still arrive as a real attachment — only pull the
        // bytes back when they'd actually fit, and fall back to the provider's
        // shareable link when they wouldn't (or when the fetch fails).
        // Direct field access (namespace-agnostic inside the package); every
        // caller now SELECTs these fields so there is no unqueried-field risk.
        Boolean isCloud = doc.Storage_Type__c == 'Cloud'
            && String.isNotBlank(doc.Cloud_File_Id__c);
        if (isCloud) {
            Long cloudSize = doc.File_Size_Bytes__c != null ? doc.File_Size_Bytes__c.longValue() : null;
            Boolean couldFit = cloudSize == null
                || (cloudSize <= MAX_SINGLE_ATTACHMENT_BYTES
                    && (runningTotal + cloudSize) <= MAX_TOTAL_ATTACHMENT_BYTES);

            if (couldFit) {
                Blob cloudBytes = fetchCloudBytes(doc);
                if (cloudBytes != null
                    && cloudBytes.size() <= MAX_SINGLE_ATTACHMENT_BYTES
                    && (runningTotal + cloudBytes.size()) <= MAX_TOTAL_ATTACHMENT_BYTES) {
                    Messaging.EmailFileAttachment catt = new Messaging.EmailFileAttachment();
                    catt.setFileName(fileName.endsWith('.pdf') ? fileName : (fileName + '.pdf'));
                    catt.setBody(cloudBytes);
                    catt.setContentType('application/pdf');
                    result.attachment = catt;
                    result.size = (Long) cloudBytes.size();
                    System.debug('tryAttachOrLink: cloud doc inlined (' + cloudBytes.size() + ' bytes)');
                    return result;
                }
            }

            if (String.isNotBlank(doc.S3_Preview_URL__c)) {
                result.downloadUrl = doc.S3_Preview_URL__c;
            } else {
                System.debug('tryAttachOrLink: Cloud doc ' + doc.Id + ' has no shareable URL');
            }
            return result;
        }

        Boolean isS3 = String.isNotBlank(doc.S3_Document_ID__c);
        Long declaredSize = doc.File_Size_Bytes__c != null ? doc.File_Size_Bytes__c.longValue() : null;
        
        // Fast path: known-large S3 doc → skip the fetch, just return presigned URL.
        if (isS3 && declaredSize != null && declaredSize > MAX_SINGLE_ATTACHMENT_BYTES) {
            result.downloadUrl = getS3PresignedUrlForDoc(doc.S3_Document_ID__c);
            return result;
        }
        
        // Fast path: would overflow the running total → S3 link, no fetch needed.
        if (isS3 && declaredSize != null && (runningTotal + declaredSize) > MAX_TOTAL_ATTACHMENT_BYTES) {
            result.downloadUrl = getS3PresignedUrlForDoc(doc.S3_Document_ID__c);
            return result;
        }
        
        // Otherwise: fetch bytes. Use them inline if they fit, link if they don't.
        Blob bytes = getDocumentBytes(doc, true);
        if (bytes == null) {
            // Bytes fetch failed. If S3-backed, try to send a link as a last resort.
            if (isS3) {
                result.downloadUrl = getS3PresignedUrlForDoc(doc.S3_Document_ID__c);
            }
            return result;
        }
        
        Long size = (Long) bytes.size();
        if (size > MAX_SINGLE_ATTACHMENT_BYTES || (runningTotal + size) > MAX_TOTAL_ATTACHMENT_BYTES) {
            // Too big to inline. Switch to link.
            if (isS3) {
                result.downloadUrl = getS3PresignedUrlForDoc(doc.S3_Document_ID__c);
            } else {
                // Tier1 doc that's too big — no presigned URL available, skip.
                System.debug('tryAttachOrLink: Tier1 doc ' + doc.Id + ' too big for email and no S3 URL');
            }
            return result;
        }
        
        Messaging.EmailFileAttachment att = new Messaging.EmailFileAttachment();
        att.setFileName(fileName.endsWith('.pdf') ? fileName : (fileName + '.pdf'));
        att.setBody(bytes);
        att.setContentType('application/pdf');
        result.attachment = att;
        result.size = size;
        return result;
    }
    
    /**
* Build the "download these files" block injected into emails when one or
* more attachments were too big to inline.
*
* Rendered as a <tr><td> so it slots directly into the outer container
* table built by BrandingService (between content-row and footer-row).
*/
    private static String buildDownloadLinksHtml(List<Map<String, String>> links) {
        Map<String, String> t = BrandingService.getEmailTokens();
        String html =
            '<tr><td class="sf-px" style="padding:0 48px 32px;font-family:-apple-system,BlinkMacSystemFont,\'Segoe UI\',Roboto,Helvetica,Arial,sans-serif;">' +
            '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%">' +
            '<tr><td style="border:1px solid ' + t.get('accentBorder') + ';background:' + t.get('accentSurface') + ';padding:18px 20px;border-radius:8px;">' +
            '<p style="margin:0 0 10px;font-size:11px;font-weight:700;letter-spacing:0.5px;text-transform:uppercase;color:' + t.get('accentText') + ';">' +
            'Available for download' +
            '</p>' +
            '<p style="margin:0 0 12px;font-size:12px;line-height:18px;color:' + t.get('accentTextDeep') + ';">' +
            'This document was too large to attach. Use the secure link below to view or download it.' +
            '</p>';
        for (Map<String, String> link : links) {
            String label = link.get('label');
            String url   = link.get('url');
            if (String.isBlank(url)) continue;
            html +=
                '<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="margin:0 0 6px;">' +
                '<tr>' +
                '<td width="18" valign="middle" style="width:18px;">' +
                '<span style="display:inline-block;width:7px;height:7px;border-radius:50%;background:' + t.get('warnCtaBg') + ';"></span>' +
                '</td>' +
                '<td style="font-size:13px;line-height:20px;">' +
                '<a href="' + url.replace('"', '%22') + '" ' +
                'style="color:' + t.get('link') + ';text-decoration:underline;font-weight:500;">' +
                (label != null ? label.escapeHtml4() : 'Download') +
                '</a>' +
                '</td>' +
                '</tr>' +
                '</table>';
        }
        html += '</td></tr></table></td></tr>';
        return html;
    }
    
    /**
* Strip filesystem-unfriendly chars and limit length so attachment filenames
* don't carry record IDs or look ugly in mail clients.
*/
    private static String sanitizeFileName(String raw) {
        if (String.isBlank(raw)) return 'document';
        String cleaned = raw.replaceAll('[\\\\/:*?"<>|]', '_').trim();
        // Drop ".pdf" / ".docx" / ".doc" suffixes if present (we re-append
        // ".pdf" later) — prevents double extensions like "Contract.docx.pdf".
        String lowerName = cleaned.toLowerCase();
        if (lowerName.endsWith('.pdf')) {
            cleaned = cleaned.substring(0, cleaned.length() - 4);
        } else if (lowerName.endsWith('.docx')) {
            cleaned = cleaned.substring(0, cleaned.length() - 5);
        } else if (lowerName.endsWith('.doc')) {
            cleaned = cleaned.substring(0, cleaned.length() - 4);
        }
        if (cleaned.length() > 80) cleaned = cleaned.substring(0, 80);
        return cleaned;
    }
    
    /** Tokens, or null if even the token layer is unavailable. */
    private static Map<String, String> safeTokens() {
        try { return BrandingService.getEmailTokens(); } catch(Exception e) { return null; }
    }
    private static String tok(Map<String, String> t, String key, String fallback) {
        if (t == null) return fallback;
        String v = t.get(key);
        return String.isBlank(v) ? fallback : v;
    }

    private static String getEmailHeader() {
        try {
            return BrandingService.getEmailHeader();
        } catch(Exception e) {
            // Last-resort shell if the branded header fails — still brand-named
            // and brand-coloured wherever the token layer is still reachable.
            Map<String, String> t = safeTokens();
            return '<div style="font-family:Arial,sans-serif;max-width:600px;margin:0 auto;">' +
                '<div style="background:' + tok(t, 'headerBg', '#0a1628') + ';padding:24px;text-align:center;">' +
                '<h1 style="color:' + tok(t, 'brandAccent', '#f59e0b') + ';margin:0;font-size:24px;letter-spacing:1px;">' +
                tok(t, 'companyName', 'SignForce').escapeHtml4() + '</h1>' +
                '</div>';
        }
    }

    private static String getEmailFooter() {
        try {
            return BrandingService.getEmailFooter();
        } catch(Exception e) {
            Map<String, String> t = safeTokens();
            return '<div style="background:' + tok(t, 'canvas', '#f6f7f9') + ';padding:16px;text-align:center;">' +
                '<p style="color:' + tok(t, 'textMuted', '#94a3b8') + ';font-size:11px;margin:0;">Powered by ' +
                tok(t, 'companyName', 'SignForce').escapeHtml4() + '</p>' +
                '</div></div>';
        }
    }
    
    private static void sendSignerEmail(Signer__c signer, Agreement__c agr) {
        sendSignerEmail(signer, agr, null, null);
    }

    /**
     * True when a User.Name is fit to print as a person's name in an email.
     *
     * Salesforce does not always hand back a readable name. When the running
     * user cannot see the queried user — and a guest signing transaction sending
     * the NEXT sequential signer's invitation is exactly that case — the platform
     * substitutes a placeholder built from the record's numeric id: the literal
     * "User" followed by ~20 digits ("User17823068604142635227"). That value is
     * not blank and it survives every String.isNotBlank guard, which is how a raw
     * id reached the "From" line of a signature request. A bare 15- or
     * 18-character record id gets the same treatment.
     *
     * Rejecting the placeholder leaves senderName empty, so the caller falls back
     * to the branded company name — the right thing to show someone who is about
     * to sign something.
     */
    @TestVisible
    /**
     * Display name for the "From" row, resolved once per agreement per transaction.
     *
     * sendSignerEmail runs once per signer, so resolving this inline cost two SOQL
     * on every iteration even though neither query varies by signer — enough to
     * halve the number of parallel signers a send could survive before hitting the
     * 100-query ceiling. Cached in a static instead: the values cannot change
     * mid-transaction.
     *
     * Prefers the agreement's CREATOR over its owner, and shows a name only when
     * it belongs to a Standard user AND actually reads as a name. Salesforce
     * substitutes a placeholder like "User17823068604142635227" when the running
     * user cannot see the queried user — which is exactly the case when a guest
     * signing transaction sends the next sequential signer their invitation. Blank
     * here means the caller falls back to the branded company name.
     */
    private static Map<Id, String> senderNameCache = new Map<Id, String>();

    private static String resolveSenderName(Id agreementId) {
        if (senderNameCache.containsKey(agreementId)) return senderNameCache.get(agreementId);

        String senderName = '';
        try {
            Agreement__c who = [
                SELECT CreatedById, OwnerId FROM Agreement__c
                WHERE Id = :agreementId LIMIT 1
            ];
            Map<Id, User> byId = new Map<Id, User>([
                SELECT Id, Name, UserType FROM User
                WHERE Id IN :new Set<Id>{ who.CreatedById, who.OwnerId }
            ]);
            User creator = byId.get(who.CreatedById);
            User owner   = byId.get(who.OwnerId);
            if (creator != null && creator.UserType == 'Standard' && isDisplayableName(creator.Name)) {
                senderName = creator.Name;
            } else if (owner != null && owner.UserType == 'Standard' && isDisplayableName(owner.Name)) {
                senderName = owner.Name;
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'resolveSenderName fell back to branding: ' + e.getMessage());
        }
        senderNameCache.put(agreementId, senderName);
        return senderName;
    }

    private static Boolean isDisplayableName(String candidate) {
        if (String.isBlank(candidate)) return false;
        String n = candidate.trim();
        if (Pattern.matches('(?i)^user\\d{10,}$', n)) return false;
        if (n.length() == 15 || n.length() == 18) {
            try {
                Id.valueOf(n);
                return false;
            } catch (Exception e) {
                // Not an id, just a name that happens to be that long — allow it.
            }
        }
        return true;
    }

    private static void sendSignerEmail(Signer__c signer, Agreement__c agr, String subjectOverride, String messageOverride) {
        String baseUrl = SignForceConfigService.getSigningSiteBaseUrl();
        String signingUrl = baseUrl + '/signature?token=' + signer.Access_Token__c;
        String headerHtml = getEmailHeader();
        String footerHtml = getEmailFooter();
        
        // Default message falls back to the agreement's stored message-to-signers.
        String effectiveMessage = String.isNotBlank(messageOverride)
            ? messageOverride
            : (String.isNotBlank(agr.Message_to_Signers__c) ? agr.Message_to_Signers__c : null);
                
                String effectiveSubject = String.isNotBlank(subjectOverride)
                ? subjectOverride
                : ('Action Required: Please sign "' + agr.Name + '"');
                    
                    // Sender display name for the meta row.
                    //
                    // The person who CREATED the agreement, not its owner. With
                    // sequential signing, signer 2's email goes out from the guest
                    // signing transaction, and ownership can also sit with an
                    // integration or auto-provisioned user — which is how signers
                    // ended up greeted by "From User17786692354307417404". Only a
                    // Standard user's name is ever shown; anything else (guest,
                    // automated process, integration users) falls through to the
                    // company name from branding, which is always presentable.
                    //
                    // The UserType gate alone is not enough: Name itself can come
                    // back as a placeholder id rather than a person (see
                    // isDisplayableName), so each candidate is checked before it is
                    // allowed onto the "From" line.
                    // Resolved through a per-transaction cache: sendForSignature
                    // calls this method once PER SIGNER, so querying the agreement
                    // and its users here cost two SOQL on every iteration and ate
                    // the 100-query ceiling as signer count grew.
                    String senderName = resolveSenderName(agr.Id);

        String sentDateFmt = DateTime.now().format('MMM dd, yyyy', orgTz());
        
        String fromName = String.isNotBlank(senderName)
            ? senderName : BrandingService.getEmailTokens().get('companyName');
        String body =
            headerHtml +
            BrandingService.emailBodyOpen() +
            BrandingService.pill('warning', 'SIGNATURE REQUESTED') +
            BrandingService.heading('You have a document to sign') +
            BrandingService.lead(
                'Please review and sign ' + BrandingService.emphasis(agr.Name) +
                ' at your earliest convenience.') +
            BrandingService.metaCard(
                new List<String>{ 'From', 'Sent' },
                new List<String>{ fromName, sentDateFmt }) +
            (String.isNotBlank(effectiveMessage)
                ? BrandingService.noteCard('warning', 'Message from sender', effectiveMessage) : '') +
            BrandingService.cta(signingUrl, 'Review & sign →', 'brand') +
            BrandingService.fallbackLink(signingUrl) +
            BrandingService.stepsStrip('What happens next',
                new List<String>{ '1. Open', '2. Review', '3. Sign' },
                new List<String>{
                    'Click the button above to open the document.',
                    'Read through and fill any required fields.',
                    'Adopt your signature and submit. Done.' }) +
            BrandingService.footnote('This link is unique to you — please don\'t forward this email. If you weren\'t expecting this, you can safely ignore it.') +
            BrandingService.emailBodyClose() +
            footerHtml;
        
        Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
        email.setToAddresses(new List<String>{ signer.Email__c });
        email.setSubject(effectiveSubject);
        String owaId = getOwaId();
        if (String.isNotBlank(owaId)) email.setOrgWideEmailAddressId(owaId);
        email.setHtmlBody(body);
        
        // CRUD: this message is built entirely from the Signer__c and
        // Agreement__c fields read above, so their read access gates the send.
        // Both are granted read to the Site Guest User, so guest signing is
        // unaffected and the branch is always taken.
        if (Schema.sObjectType.Signer__c.isAccessible()
            && Schema.sObjectType.Agreement__c.isAccessible()) {
            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ email });
        }
        signer.Status__c = 'Sent';
        update signer;
        AuditTrailService.log(agr.Id, 'Email Delivered', signer.Email__c, null, null);
    }
    
    public static String generateToken() {
        Blob b = Crypto.generateAesKey(128);
        return EncodingUtil.convertToHex(b);
    }
    
    public class AgreementException extends Exception {}
}