/**
 * SignForceConfigServiceGuest - guest-side copy of SignForceConfigService.
 *
 * Reads SignForce_Config__mdt (custom metadata) and the SignForce_Admin_Config__c custom
 * setting for the GUEST signing flows: the Lambda endpoint (AgreementControllerGuest,
 * AgreementServiceGuest, GuestSigningApi, DocumentEditorControllerGuest, IntegrationServiceGuest),
 * the signing-site base URL (AgreementServiceGuest), the CORS allow-list (PDFProxyRestService)
 * and the OAuth client credentials used by the cloud push (IntegrationServiceGuest).
 * Internal callers use SignForceConfigService.
 *
 * SHARING: `with sharing`. Custom metadata and custom settings are not governed by record
 * sharing, so the keyword does not change what any method returns.
 *
 * EXCEPTION TYPE: failures still throw SignForceConfigService.ConfigurationException (the
 * ORIGINAL type, not a copy), so existing `catch`/`instanceof` checks keep working. That
 * qualifier is the only edit made to the copied method bodies.
 *
 * getAllowedOrigins is GUEST-ONLY and was moved here from SignForceConfigService.
 * The rest are verbatim copies. This class keeps its own transaction cache and its own
 * lambdaEndpointOverride test hook (tests of guest code must set THIS one).
 */
public with sharing class SignForceConfigServiceGuest {

    @TestVisible
    public static String lambdaEndpointOverride;

    // Hardcoded fallbacks — match field defaults in the Default CMT record.
    private static final String  DEFAULT_TIER             = 'Tier1';

    // Empty by default. Admin MUST configure via CMT for callouts to succeed.
    // (Was previously a real account-specific URL — security finding #1 in
    // the project README. AppExchange-distributable code should not ship
    // with a hardcoded endpoint.)
    private static final String  DEFAULT_LAMBDA_ENDPOINT  = '';

    private static final String  DEFAULT_S3_BUCKET        = 'signforce-documents';

    private static final Long    DEFAULT_TIER1_MAX_BYTES  = 3145728L;     // 3 MB

    private static final Long    DEFAULT_CHUNK_THRESHOLD  = 7340032L;     // 7 MB

    private static final Long    DEFAULT_MAX_UPLOAD       = 20971520L;    // 20 MB

    private static final String  DEFAULT_ALLOWED_ORIGINS  = '';

    // Cached for the transaction. CMT is fast but not free; one SOQL is plenty.
    private static SignForce_Config__mdt cached;

    private static Boolean cacheLoaded = false;

    private static String cachedNamespacePrefix = null;

    private static String getNamespacePrefix() {
        if (cachedNamespacePrefix == null) {
            String objName = SignForce_Config__mdt.SObjectType.getDescribe().getName();
            Integer idx = objName.indexOf('__SignForce_Config__mdt');
            if (idx > -1) {
                cachedNamespacePrefix = objName.substring(0, idx + 2);
            } else {
                cachedNamespacePrefix = '';
            }
        }
        return cachedNamespacePrefix;
    }

    private static SignForce_Config__mdt load() {
        if (cacheLoaded) return cached;
        cacheLoaded = true;
        try {
            // Build SOQL dynamically so missing fields (in older orgs that
            // haven't deployed the security update) don't blow up the query.
            // We try the full SELECT first, then degrade.
            List<String> fields = new List<String>{
                'Storage_Tier__c', 'Lambda_Endpoint__c', 'S3_Bucket__c',
                'Tier1_Max_Bytes__c', 'Chunk_Threshold_Bytes__c',
                'Max_Upload_Bytes__c', 'Doc_Gen_Lambda_Endpoint__c',
                'NamespacePrefix'
            };
            // Optional new fields — include only if present on the type.
            // Typed reference auto-resolves the namespace in a managed package
            // (getGlobalDescribe() keys are namespaced, so a literal
            //  .get('SignForce_Config__mdt') would return null once packaged).
            Map<String, Schema.SObjectField> sf =
                SignForce_Config__mdt.SObjectType.getDescribe().fields.getMap();
            // Namespace-agnostic: in a managed package the field-map keys can be
            // namespaced (ns__allowed_origins__c), so match on the bare name too.
            if (hasField(sf, 'allowed_origins__c'))      fields.add('Allowed_Origins__c');
            if (hasField(sf, 'image_host_allowlist__c')) fields.add('Image_Host_Allowlist__c');
            if (hasField(sf, 'google_client_id__c'))     fields.add('Google_Client_ID__c');
            if (hasField(sf, 'google_client_secret__c')) fields.add('Google_Client_Secret__c');
            if (hasField(sf, 'microsoft_client_id__c'))     fields.add('Microsoft_Client_ID__c');
            if (hasField(sf, 'microsoft_client_secret__c')) fields.add('Microsoft_Client_Secret__c');

            String ns = getNamespacePrefix();
            String devName = 'Default';
            String qualifiedDevName = String.isNotBlank(ns) ? ns + devName : devName;

            String soql = 'SELECT ' + String.join(fields, ',') +
                          ' FROM SignForce_Config__mdt' +
                          ' WHERE DeveloperName = \'' + devName + '\'' +
                          ' OR DeveloperName = \'' + qualifiedDevName + '\'';
            List<SignForce_Config__mdt> recs = Database.query(soql);
            if (!recs.isEmpty()) {
                SignForce_Config__mdt chosen = recs[0];
                for (SignForce_Config__mdt r : recs) {
                    Boolean isLocal = String.isBlank(r.NamespacePrefix);
                    Boolean hasEndpoint = String.isNotBlank(r.Lambda_Endpoint__c);
                    if (isLocal && hasEndpoint) {
                        chosen = r;
                        break;
                    } else if (hasEndpoint) {
                        chosen = r;
                    } else if (isLocal && String.isBlank(chosen.Lambda_Endpoint__c)) {
                        chosen = r;
                    }
                }
                cached = chosen;
            }
        } catch (Exception e) {
            // CMT not deployed yet, or query failed — fall through to defaults.
            System.debug('SignForceConfigService: load failed - ' + e.getMessage());
        }
        return cached;
    }

    @TestVisible
    private static void resetCache() {
        cached = null;
        cacheLoaded = false;
    }

    /**
     * Namespace-safe field-existence check. Works whether the describe map
     * keys are bare ('allowed_origins__c') in an unmanaged org or namespaced
     * ('ns__allowed_origins__c') in a managed package.
     */
    private static Boolean hasField(Map<String, Schema.SObjectField> sf, String bareName) {
        String target = bareName.toLowerCase();
        if (sf.containsKey(target)) return true;
        for (String k : sf.keySet()) {
            if (k.endsWith('__' + target)) return true;
        }
        return false;
    }

    public static String getStorageTier() {
        SignForce_Config__mdt c = load();
        return c != null && String.isNotBlank(c.Storage_Tier__c) ? c.Storage_Tier__c : DEFAULT_TIER;
    }

    public static String getLambdaEndpoint() {
        if (lambdaEndpointOverride != null) return lambdaEndpointOverride;
        SignForce_Config__mdt c = load();
        String ep = c != null && String.isNotBlank(c.Lambda_Endpoint__c) ? c.Lambda_Endpoint__c : DEFAULT_LAMBDA_ENDPOINT;
        if (String.isBlank(ep)) {
            // Surface a clear, actionable error rather than a network failure.
            throw new SignForceConfigService.ConfigurationException(
                'Stamping Lambda endpoint is not configured. Set Lambda_Endpoint__c on SignForce_Config__mdt (Default record) before using stamping features.'
            );
        }
        return ep;
    }

    public static String getS3Bucket() {
        SignForce_Config__mdt c = load();
        return c != null && String.isNotBlank(c.S3_Bucket__c) ? c.S3_Bucket__c : DEFAULT_S3_BUCKET;
    }

    public static Long getTier1MaxBytes() {
        SignForce_Config__mdt c = load();
        return c != null && c.Tier1_Max_Bytes__c != null ? (Long) c.Tier1_Max_Bytes__c : DEFAULT_TIER1_MAX_BYTES;
    }

    public static Long getChunkThresholdBytes() {
        SignForce_Config__mdt c = load();
        return c != null && c.Chunk_Threshold_Bytes__c != null ? (Long) c.Chunk_Threshold_Bytes__c : DEFAULT_CHUNK_THRESHOLD;
    }

    public static Long getMaxUploadBytes() {
        SignForce_Config__mdt c = load();
        return c != null && c.Max_Upload_Bytes__c != null ? (Long) c.Max_Upload_Bytes__c : DEFAULT_MAX_UPLOAD;
    }

    /**
     * CORS allowlist for PDFProxyRestService. Comma-separated list of origins
     * (e.g. "https://signforce.example.com,https://portal.example.com").
     * The org's My Domain is always allowed automatically — admins only need
     * to add EXTRA origins (Experience Cloud custom domains, etc).
     */
    public static String getAllowedOrigins() {
        SignForce_Config__mdt c = load();
        try {
            Object v = c != null ? c.get('Allowed_Origins__c') : null;
            return v != null ? String.valueOf(v) : DEFAULT_ALLOWED_ORIGINS;
        } catch (Exception e) {
            return DEFAULT_ALLOWED_ORIGINS;
        }
    }

    /**
     * Base URL of the org's Experience Cloud signing site (domain + path prefix),
     * e.g. "https://acme.my.site.com/sign". Read from the SignForce_Admin_Config__c
     * custom setting, set by the admin via the SignForce Admin Configuration screen.
     * Signing links are built as {base}/signature?token=...
     *
     * Throws if not configured so a broken / wrong-org link is never emailed
     * (replaces the old hardcoded dev-org URL).
     */
    public static String getSigningSiteBaseUrl() {
        SignForce_Admin_Config__c cs = SignForce_Admin_Config__c.getOrgDefaults();
        String url = (cs != null) ? cs.Signing_Site_Base_URL__c : null;
        if (String.isNotBlank(url)) {
            return url.trim().removeEnd('/');
        }
        if (Test.isRunningTest()) {
            // The org-default custom setting isn't seeded in most tests; return a
            // placeholder so send-flow tests don't fail on missing config.
            return 'https://test.example.com/sign';
        }
        throw new SignForceConfigService.ConfigurationException(
            'Signing site URL is not configured. An administrator must set ' +
            '"Signing Site Base URL" in SignForce Admin Configuration before sending for signature.'
        );
    }

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getClientConfig() {
        // For the LWC: surface the Lambda endpoint so createAgreement can
        // do direct browser-to-Lambda uploads (Tier 2/3). The endpoint
        // itself is not a secret — it's protected at the Lambda layer
        // by orgId validation. What we don't surface is anything else
        // that's useful only server-side.
        //
        // We try/catch around getLambdaEndpoint() because that method
        // throws SignForceConfigService.ConfigurationException when the CMT field is blank.
        // For the @wire path that's not actionable to the user — they
        // just see the wizard fail to load. So we degrade to empty
        // string and let the LWC's upload code show a clearer error
        // ("Lambda endpoint not configured") at the moment of upload.
        String lambda = '';
        try {
            lambda = getLambdaEndpoint();
        } catch (SignForceConfigService.ConfigurationException ce) {
            // Leave blank; LWC will show the right error if/when used.
        }
        // Which cloud provider (if any) documents will be pushed to. Resolved from
        // the custom setting only — no callout — so uploads pay nothing for this.
        // A stale OAuth token still reports "connected"; the push itself surfaces
        // that, and the upload path doesn't depend on the token being live.
        String cloudProvider;
        try {
            cloudProvider = IntegrationServiceGuest.primaryProvider();
        } catch (Exception e) {
            cloudProvider = null;
        }

        return new Map<String, Object>{
            'tier'                 => getStorageTier(),
            's3Bucket'             => getS3Bucket(),
            'tier1MaxBytes'        => getTier1MaxBytes(),
            'chunkThresholdBytes'  => getChunkThresholdBytes(),
            'maxUploadBytes'       => getMaxUploadBytes(),
            'orgId'                => UserInfo.getOrganizationId(),
            'lambdaEndpoint'       => lambda,
            'cloudProvider'        => cloudProvider,
            'cloudConnected'       => cloudProvider != null
        };
    }

    public static void applyLambdaAuth(HttpRequest req) {
        // No-op or custom headers for Lambda authentication if required.
    }

    public static String getGoogleClientId() {
        SignForce_Admin_Config__c cs = SignForce_Admin_Config__c.getOrgDefaults();
        String val = cs != null ? cs.Google_Client_ID__c : '';
        if (String.isBlank(val)) {
            SignForce_Config__mdt c = load();
            try {
                Object v = c != null ? c.get('Google_Client_ID__c') : null;
                if (v != null) val = String.valueOf(v);
            } catch (Exception e) {}
        }
        return val;
    }

    public static String getGoogleClientSecret() {
        SignForce_Admin_Config__c cs = SignForce_Admin_Config__c.getOrgDefaults();
        String val = cs != null ? cs.Google_Client_Secret__c : '';
        if (String.isBlank(val)) {
            SignForce_Config__mdt c = load();
            try {
                Object v = c != null ? c.get('Google_Client_Secret__c') : null;
                if (v != null) val = String.valueOf(v);
            } catch (Exception e) {}
        }
        return val;
    }

    public static String getMicrosoftClientId() {
        SignForce_Admin_Config__c cs = SignForce_Admin_Config__c.getOrgDefaults();
        String val = cs != null ? cs.Microsoft_Client_ID__c : '';
        if (String.isBlank(val)) {
            SignForce_Config__mdt c = load();
            try {
                Object v = c != null ? c.get('Microsoft_Client_ID__c') : null;
                if (v != null) val = String.valueOf(v);
            } catch (Exception e) {}
        }
        return val;
    }

    public static String getMicrosoftClientSecret() {
        SignForce_Admin_Config__c cs = SignForce_Admin_Config__c.getOrgDefaults();
        String val = cs != null ? cs.Microsoft_Client_Secret__c : '';
        if (String.isBlank(val)) {
            SignForce_Config__mdt c = load();
            try {
                Object v = c != null ? c.get('Microsoft_Client_Secret__c') : null;
                if (v != null) val = String.valueOf(v);
            } catch (Exception e) {}
        }
        return val;
    }
}
