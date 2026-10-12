/**
 * PDFProxyRestService — public REST endpoint that re-fetches a ContentVersion
 * via the org REST API to bypass Apex heap when streaming large PDFs.
 *
 * SECURITY (rewritten):
 *   This endpoint is public (guest-reachable). The previous version accepted
 *   any cvId with no auth — meaning any caller could request any file in the
 *   org by guessing 18-char Ids, with `Access-Control-Allow-Origin: *` making
 *   it cross-origin readable from anywhere on the internet. That is fixed
 *   here. Two requirements every request must pass:
 *
 *     1. `token` query parameter — must resolve to a valid Signer__c
 *        (not expired, not revoked, not already signed).
 *     2. `cvId` must belong to the agreement that token is for. Verified via
 *        SignForceAuthz.requireContentVersionForTokenRest.
 *
 *   CORS is also tightened: instead of `*`, we echo back the request Origin
 *   only if it matches an allowlisted host (Salesforce Site / Experience
 *   Cloud domain — configurable via Custom Metadata).
 */
@RestResource(urlMapping='/pdfproxy/*')
global with sharing class PDFProxyRestService {

    @HttpGet
    global static void getPdf() {
        RestRequest req  = RestContext.request;
        RestResponse res = RestContext.response;

        String token = req.params.get('token');
        String cvId  = req.params.get('cvId');

        // Tighten CORS: only allow our own org domain + configured Site
        // origins. We echo the request Origin if it matches; otherwise we
        // omit the header entirely (browsers will then block the response).
        applyCorsHeaders(req, res);

        if (String.isBlank(cvId)) {
            res.statusCode = 400;
            res.responseBody = Blob.valueOf('Missing cvId');
            return;
        }
        if (String.isBlank(token)) {
            res.statusCode = 401;
            res.responseBody = Blob.valueOf('Missing token');
            return;
        }

        // Authz: validate token AND that cvId is for that agreement.
        try {
            SignForceAuthz.requireContentVersionForTokenRest(token, (Id) cvId);
        } catch (SignForceAuthz.AuthzException ae) {
            res.statusCode = 403;
            res.responseBody = Blob.valueOf('Access denied');
            return;
        } catch (Exception other) {
            // Bad cvId format etc.
            res.statusCode = 400;
            res.responseBody = Blob.valueOf('Bad request');
            return;
        }

        try {
            Http http = new Http();
            HttpRequest http_req = new HttpRequest();
            String baseUrl = URL.getOrgDomainUrl().toExternalForm();
            http_req.setEndpoint(baseUrl + '/services/data/v60.0/sobjects/ContentVersion/' + cvId + '/VersionData');
            http_req.setMethod('GET');
            http_req.setHeader('Authorization', 'Bearer ' + UserInfo.getSessionId());
            http_req.setTimeout(120000);

            HttpResponse http_res = http.send(http_req);

            if (http_res.getStatusCode() == 200) {
                res.statusCode = 200;
                res.addHeader('Content-Type', 'application/pdf');
                // Cache headers — short-lived since this is auth-gated content.
                res.addHeader('Cache-Control', 'private, max-age=60');
                res.responseBody = http_res.getBodyAsBlob();
            } else {
                res.statusCode = 502;
                res.responseBody = Blob.valueOf('Upstream error: ' + http_res.getStatusCode());
            }
        } catch (Exception e) {
            // Don't leak internals to the client; log server-side.
            System.debug(LoggingLevel.ERROR, '[PDFProxyRestService] ' + e.getMessage());
            res.statusCode = 500;
            res.responseBody = Blob.valueOf('Error');
        }
    }

    /**
     * Apply CORS headers if and only if the request Origin is allowlisted.
     * Allowlist = the org's My Domain + any extra origins configured in
     * SignForceConfigServiceGuest.getAllowedOrigins() (comma-separated CMT field).
     *
     * If the Origin doesn't match, we don't set Access-Control-Allow-Origin
     * at all — the browser will block cross-origin reads, which is exactly
     * what we want.
     */
    private static void applyCorsHeaders(RestRequest req, RestResponse res) {
        String origin = req.headers != null ? req.headers.get('Origin') : null;
        if (String.isBlank(origin)) return;

        Set<String> allowed = new Set<String>();
        // Always allow our own domain (covers Lightning + Site under same MyDomain).
        try {
            allowed.add(URL.getOrgDomainUrl().toExternalForm());
        } catch (Exception ignore) {}

        // Plus any explicitly configured origins (Experience Cloud custom domain etc).
        String configured = SignForceConfigServiceGuest.getAllowedOrigins();
        if (String.isNotBlank(configured)) {
            for (String s : configured.split(',')) {
                String trimmed = s.trim();
                if (String.isNotBlank(trimmed)) allowed.add(trimmed);
            }
        }

        if (allowed.contains(origin)) {
            res.addHeader('Access-Control-Allow-Origin', origin);
            res.addHeader('Vary', 'Origin');
        }
        // else: omit, so browser blocks cross-origin read.
    }
}