/**
 * SignForceConfigService — reads SignForce_Config__mdt Custom Metadata.
 *
 * Looks up the record DeveloperName='Default' (the one shipped in customMetadata/).
 * Falls back to safe defaults if the record isn't deployed yet.
 *
 * SECURITY (post-AppExchange-prep):
 *   The Lambda endpoint default is now an empty string. Previously it carried
 *   a real account-specific URL, which is fine for a single-tenant install
 *   but unacceptable for a managed package — every customer would silently
 *   start hitting our AWS account. Admins must configure the CMT before any
 *   callouts will succeed. Apex methods that depend on the endpoint should
 *   throw a clear error when blank (see getLambdaEndpoint / getDocGenLambdaEndpoint).
 *
 *   New fields added to support security hardening:
 *     - Allowed_Origins__c       — CORS allowlist for PDFProxyRestService
 *     - Image_Host_Allowlist__c  — host allowlist for MergeContextBuilder.fetchImages
 *
 *   These fields must exist on SignForce_Config__mdt before the security
 *   patches will work. See the updated CMT XML shipped alongside this class.
 *
 * To change config: edit force-app/main/default/customMetadata/SignForce_Config.Default.md-meta.xml
 * and deploy. (Or edit in-org at Setup > Custom Metadata Types > SignForce Config > Manage Records.)
 *
 * SHARING / GUEST SPLIT: `with sharing`. Custom metadata and custom settings are not governed by
 * record sharing, so the keyword does not change behaviour. The guest signing flows use
 * SignForceConfigServiceGuest (verbatim copies of the methods they need); getAllowedOrigins
 * (guest-only, PDFProxyRestService) moved there. ConfigurationException is defined here and is
 * thrown by BOTH classes.
 */
public with sharing class SignForceConfigService {

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
    private static final String  DEFAULT_DOC_GEN_LAMBDA_ENDPOINT = '';
    private static final String  DEFAULT_ALLOWED_ORIGINS  = '';
    private static final String  DEFAULT_IMAGE_HOST_ALLOWLIST = ''; // empty = allow any public host (still blocks private IPs)

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
            throw new ConfigurationException(
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
     * Pick the right tier for a given file size.
     * - Org tier Tier1 → always Tier1.
     * - Otherwise: small files (<= tier1MaxBytes) use Tier1, files above
     *   chunkThreshold are upgraded to Tier3, the middle range uses org tier.
     */
    public static String resolveTierForSize(Long fileSize) {
        String orgTier = getStorageTier();
        if (orgTier == 'Tier1') return 'Tier1';
        if (fileSize == null || fileSize <= 0) return orgTier;

        if (fileSize <= getTier1MaxBytes()) return 'Tier1';
        if (fileSize > getChunkThresholdBytes()) return 'Tier3';
        return orgTier;
    }

    public static String getDocGenLambdaEndpoint() {
        if (lambdaEndpointOverride != null) return lambdaEndpointOverride;
        SignForce_Config__mdt c = load();
        String ep = c != null && String.isNotBlank(c.Doc_Gen_Lambda_Endpoint__c)
            ? c.Doc_Gen_Lambda_Endpoint__c
            : DEFAULT_DOC_GEN_LAMBDA_ENDPOINT;
        if (String.isBlank(ep)) {
            throw new ConfigurationException(
                'Doc Gen Lambda endpoint is not configured. Set Doc_Gen_Lambda_Endpoint__c on SignForce_Config__mdt (Default record) before using document generation.'
            );
        }
        return ep;
    }

    /**
     * Host allowlist for image fetches in MergeContextBuilder.
     * Comma-separated list of allowed hostnames (e.g. "cdn.example.com,images.salesforce.com").
     *
     * Empty → all public hosts allowed (private IPs are still blocked unconditionally).
     * Setting this is recommended for AppExchange security review.
     */
    public static String getImageHostAllowlist() {
        SignForce_Config__mdt c = load();
        try {
            Object v = c != null ? c.get('Image_Host_Allowlist__c') : null;
            return v != null ? String.valueOf(v) : DEFAULT_IMAGE_HOST_ALLOWLIST;
        } catch (Exception e) {
            return DEFAULT_IMAGE_HOST_ALLOWLIST;
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
        throw new ConfigurationException(
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
        // throws ConfigurationException when the CMT field is blank.
        // For the @wire path that's not actionable to the user — they
        // just see the wizard fail to load. So we degrade to empty
        // string and let the LWC's upload code show a clearer error
        // ("Lambda endpoint not configured") at the moment of upload.
        String lambda = '';
        try {
            lambda = getLambdaEndpoint();
        } catch (ConfigurationException ce) {
            // Leave blank; LWC will show the right error if/when used.
        }
        // Which cloud provider (if any) documents will be pushed to. Resolved from
        // the custom setting only — no callout — so uploads pay nothing for this.
        // A stale OAuth token still reports "connected"; the push itself surfaces
        // that, and the upload path doesn't depend on the token being live.
        String cloudProvider;
        try {
            cloudProvider = IntegrationService.primaryProvider();
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

    // OAuth app credentials: the admin-entered value (SignForce_Admin_Config__c
    // custom setting, written by the SignForce Admin Configuration wizard) wins;
    // the packaged CMT record is only a fallback for orgs that never opened the
    // wizard. If the CMT won instead, credentials typed into the wizard would
    // save but silently never be used.

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

    public class ConfigurationException extends Exception {}
}