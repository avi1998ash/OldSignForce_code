/**
 * SignForceQuery — RETIRED. Body commented out, not deleted.
 *
 * A centralized SOQL helper wrapping Database.queryWithBinds with consistent
 * FLS semantics. It never acquired a production caller: the only references
 * were its own test class, one no-assert coverage test, and the guest
 * permission set.
 *
 * Confirmed unreachable before retiring it - no class, trigger, page or LWC in
 * the repo calls runWithFLS / runWithoutFLS outside of tests.
 *
 * Kept as an empty class rather than deleted because this ships in a managed
 * package: removing a class is awkward to reverse once a version is released.
 *
 * The implementation is preserved below, commented line by line because it
 * contains its own doc blocks and Apex block comments do not nest. If it is
 * revived, the note it carried is still worth reading: USER_MODE and
 * WITH SECURITY_ENFORCED are mutually exclusive from API 60 onward, which is
 * why runWithFLS stripped the clause before querying.
 */
public inherited sharing class SignForceQuery {

    // Intentionally empty. Retired implementation retained below for reference.

    //
    //     /**
    //      * Run a query with FLS and sharing enforced via AccessLevel.USER_MODE.
    //      * Throws SignForceFLSException on FLS denial.
    //      *
    //      * NOTE: The query string MUST NOT contain `WITH SECURITY_ENFORCED` —
    //      * that clause is incompatible with USER_MODE in API 60+. If it's
    //      * present we strip it out (defensive backward compat).
    //      */
    //     public static List<SObject> runWithFLS(String soql, Map<String, Object> binds) {
    //         String clean = stripSecurityEnforced(soql);
    //         try {
    //             return Database.queryWithBinds(clean, binds, AccessLevel.USER_MODE);
    //         } catch (System.QueryException qe) {
    //             // FLS failures sometimes surface as QueryException
    //             String msg = qe.getMessage() != null ? qe.getMessage() : '';
    //             if (msg.contains('insufficient access') || msg.contains('SECURITY_ENFORCED')) {
    //                 throw new SignForceFLS.SignForceFLSException(
    //                     'You don\'t have access to all fields in this query. Contact your administrator.'
    //                 );
    //             }
    //             throw qe;
    //         } catch (System.SecurityException se) {
    //             // USER_MODE FLS failure throws SecurityException
    //             throw new SignForceFLS.SignForceFLSException(
    //                 'You don\'t have access to all fields in this query. Contact your administrator.'
    //             );
    //         }
    //     }
    //
    //     /**
    //      * Run a query in SYSTEM_MODE (bypass FLS and sharing). Logs the bypass
    //      * reason for security audit. Use only for legitimate cases — see class doc.
    //      */
    //     public static List<SObject> runWithoutFLS(
    //         String soql,
    //         Map<String, Object> binds,
    //         String bypassReason
    //     ) {
    //         SignForceFLS.bypassRequired(bypassReason);
    //         // Same defensive strip — WITH SECURITY_ENFORCED + SYSTEM_MODE is
    //         // legal but confusing (the SECURITY_ENFORCED would still enforce FLS,
    //         // defeating the bypass). Strip to keep intent clear.
    //         String clean = stripSecurityEnforced(soql);
    //         return Database.queryWithBinds(clean, binds, AccessLevel.SYSTEM_MODE);
    //     }
    //
    //     /**
    //      * Run a USER_MODE query without binds. Convenience wrapper.
    //      */
    //     public static List<SObject> runWithFLS(String soql) {
    //         return runWithFLS(soql, new Map<String, Object>());
    //     }
    //
    //     // ─────────────────────────────────────────────────────────────
    //     // Internal
    //     // ─────────────────────────────────────────────────────────────
    //
    //     /**
    //      * Defensive: remove any `WITH SECURITY_ENFORCED` from the query string.
    //      * Callers may have added it manually expecting old behavior, and the
    //      * combination with USER_MODE is illegal at runtime in API 60+.
    //      *
    //      * Returns the soql unchanged if no SECURITY_ENFORCED clause is present.
    //      */
    //     @TestVisible
    //     private static String stripSecurityEnforced(String soql) {
    //         if (String.isBlank(soql)) return soql;
    //         if (!soql.containsIgnoreCase('WITH SECURITY_ENFORCED')) return soql;
    //
    //         // Case-insensitive replace. The clause can appear with various
    //         // whitespace; normalize then remove.
    //         String normalized = soql.replaceAll('(?i)\\s+WITH\\s+SECURITY_ENFORCED\\b', ' ');
    //         // Collapse double spaces from the removal
    //         return normalized.replaceAll('\\s{2,}', ' ').trim();
    //     }
    //
    //     /**
    //      * BACKWARD COMPAT: kept @TestVisible because the existing
    //      * SignForceQueryTest still asserts on this method's behavior.
    //      *
    //      * Returns the soql unchanged if it already lacks SECURITY_ENFORCED;
    //      * adds it before any tail clause (ORDER BY / LIMIT / etc.) otherwise.
    //      *
    //      * This method is NO LONGER called by runWithFLS — it's preserved for
    //      * test compatibility only. If you need to add SECURITY_ENFORCED to a
    //      * query string for some other purpose, call this. But do NOT pass the
    //      * result back to runWithFLS — USER_MODE will reject it.
    //      */
    //     @TestVisible
    //     private static String ensureSecurityEnforced(String soql) {
    //         if (String.isBlank(soql)) return soql;
    //         if (soql.containsIgnoreCase('WITH SECURITY_ENFORCED')) return soql;
    //
    //         String[] tailKeywords = new String[]{
    //             'ORDER BY', 'GROUP BY', 'LIMIT', 'FOR UPDATE', 'FOR VIEW', 'FOR REFERENCE'
    //         };
    //         Integer earliestTail = -1;
    //         for (String kw : tailKeywords) {
    //             Integer idx = soql.toUpperCase().indexOf(kw);
    //             if (idx > 0 && (earliestTail == -1 || idx < earliestTail)) {
    //                 earliestTail = idx;
    //             }
    //         }
    //
    //         if (earliestTail > 0) {
    //             return soql.substring(0, earliestTail).trim()
    //                 + ' WITH SECURITY_ENFORCED '
    //                 + soql.substring(earliestTail);
    //         }
    //         return soql.trim() + ' WITH SECURITY_ENFORCED';
    //     }
    //
}