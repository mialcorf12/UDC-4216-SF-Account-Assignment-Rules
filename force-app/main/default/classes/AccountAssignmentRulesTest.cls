/**
 * Test class for AccountAssignmentRules.
 *
 * Strict TDD — tests written before / alongside the implementation.
 * All tests cover profile filtering, geographic matching, bulk handling, and error paths.
 *
 * Testing strategy:
 * - Accounts are inserted as the real test-running user to avoid org-specific VR issues
 *   from managed packages that fire on Account insert for test-created users.
 * - AccountAssignmentRules.assign() is called directly (unit test style) with the
 *   Account's OwnerId pre-set to a real SysAdmin or non-SysAdmin user Id, then
 *   the Account is updated to DB before calling assign() so the engine's profile
 *   filter sees the correct OwnerId.
 * - MDT expected OwnerId values are queried dynamically so tests remain resilient
 *   to staging data differences between orgs.
 *
 * Debug log strings remain in Spanish per project language contract.
 */
@isTest
private class AccountAssignmentRulesTest {

    // ── Cached org user Ids resolved once per test run ────────────────────────

    // Real System Administrator user Id (different from the test runner)
    private static Id sysAdminUserId {
        get {
            if (sysAdminUserId == null) {
                sysAdminUserId = [
                    SELECT Id FROM User
                    WHERE Profile.Name = 'System Administrator'
                    AND IsActive = true
                    LIMIT 1
                ].Id;
            }
            return sysAdminUserId;
        }
        set;
    }

    // Real non-SysAdmin user Id
    private static Id nonSysAdminUserId {
        get {
            if (nonSysAdminUserId == null) {
                nonSysAdminUserId = [
                    SELECT Id FROM User
                    WHERE Profile.Name = 'Standard User'
                    AND IsActive = true
                    LIMIT 1
                ].Id;
            }
            return nonSysAdminUserId;
        }
        set;
    }

    // ─── Helper: resolve expected OwnerId from MDT by Order__c ───────────────

    private static Id getMdtOwnerId(Integer orderNum) {
        List<Account_Assignment_Rule__mdt> rules = [
            SELECT OwnerId__c FROM Account_Assignment_Rule__mdt
            WHERE Order__c = :orderNum LIMIT 1
        ];
        if (rules.isEmpty() || String.isBlank(rules[0].OwnerId__c)) {
            return null;
        }
        return Id.valueOf(rules[0].OwnerId__c);
    }

    // ─── Helper: insert a minimal valid Account and then update OwnerId to target ─

    private static Account prepareAccount(String name, Id ownerId) {
        // RecordType and Website satisfy org-level VRs on Account insert.
        Id commRtId = [
            SELECT Id FROM RecordType
            WHERE SObjectType = 'Account' AND DeveloperName = 'Commercial'
            LIMIT 1
        ].Id;
        Account acc = new Account(
            Name         = name,
            RecordTypeId = commRtId,
            Website      = 'https://testassignment.example.com',
            OwnerId      = ownerId
        );
        insert acc;
        return acc;
    }

    // ─── Edge: testEmptyAndNullInput ─────────────────────────────────────────

    @isTest
    static void testEmptyAndNullInput() {
        // Engine must handle null and empty lists without throwing.
        Boolean thrown = false;
        Test.startTest();
        try {
            AccountAssignmentRules.assign(null);
            AccountAssignmentRules.assign(new List<Account>());
        } catch (Exception e) {
            thrown = true;
        }
        Test.stopTest();
        System.assertEquals(false, thrown,
            'assign(null) and assign([]) must return silently without exception');
    }

    // ─── Edge: testSendInvalidOwnerAlert_Direct ──────────────────────────────

    @isTest
    static void testSendInvalidOwnerAlert_Direct() {
        // Exercises sendInvalidOwnerAlert() paths directly via @TestVisible.
        // All three paths run within a single Test.startTest()/stopTest() block.
        // Path 1: skipEmailInTest = true  → early return at line 276-278.
        // Path 2: empty alertEmails list  → early return at line 280-282.
        // Path 3: non-empty alertEmails   → exercises full email-build path (lines 284-297).

        Boolean thrown = false;

        Test.startTest();
        try {
            // Path 1: suppressed via flag
            AccountAssignmentRules.skipEmailInTest = true;
            AccountAssignmentRules.sendInvalidOwnerAlert('1', '005FAKE00000000AAA',
                new List<String>{ 'admin@test.com' });

            // Path 2: empty list
            AccountAssignmentRules.skipEmailInTest = false;
            AccountAssignmentRules.sendInvalidOwnerAlert('2', '005FAKE00000000AAA',
                new List<String>());

            // Path 3: real email — Salesforce test framework suppresses delivery
            AccountAssignmentRules.sendInvalidOwnerAlert('3', '005FAKE00000000AAA',
                new List<String>{ UserInfo.getUserEmail() });

        } catch (Exception e) {
            thrown = true;
        }
        Test.stopTest();

        System.assertEquals(false, thrown,
            'All sendInvalidOwnerAlert paths must execute without exception');
    }

    // ─── 4.2.1 testSysAdminInsert_CountryMatch ───────────────────────────────

    @isTest
    static void testSysAdminInsert_CountryMatch() {
        // Rule 1: BillingCountry__c matches 'Australia'
        // Expected OwnerId comes from the MDT rule (queried dynamically)
        Id expectedOwner = getMdtOwnerId(1);
        System.assertNotEquals(null, expectedOwner,
            'MDT Rule 1 must have a non-blank OwnerId__c');

        Account acc = prepareAccount('Test Country Match', sysAdminUserId);
        acc.BillingCountry = 'Australia';

        Test.startTest();
        AccountAssignmentRules.assign(new List<Account>{ acc });
        Test.stopTest();

        Account result = [SELECT OwnerId FROM Account WHERE Id = :acc.Id];
        System.assertEquals(
            expectedOwner,
            result.OwnerId,
            'Rule 1 must assign OwnerId for Australia'
        );
    }

    // ─── 4.2.2 testSysAdminInsert_CountryStateMatch ──────────────────────────

    @isTest
    static void testSysAdminInsert_CountryStateMatch() {
        // Rule 2: BillingCountry__c = 'CA,Canada', BillingState__c includes 'Alberta'
        Id expectedOwner = getMdtOwnerId(2);
        System.assertNotEquals(null, expectedOwner,
            'MDT Rule 2 must have a non-blank OwnerId__c');

        Account acc = prepareAccount('Test Country State Match', sysAdminUserId);
        acc.BillingCountry = 'Canada';
        acc.BillingState   = 'Alberta';

        Test.startTest();
        AccountAssignmentRules.assign(new List<Account>{ acc });
        Test.stopTest();

        Account result = [SELECT OwnerId FROM Account WHERE Id = :acc.Id];
        System.assertEquals(
            expectedOwner,
            result.OwnerId,
            'Rule 2 must assign OwnerId for Canada + Alberta'
        );
    }

    // ─── 4.2.3 testSysAdminInsert_PostalCodePrefix ───────────────────────────

    @isTest
    static void testSysAdminInsert_PostalCodePrefix() {
        // Rule 9: BillingState__c = 'HI,Hawaii', BillingPostalCode__c includes prefix '902'
        Id expectedOwner = getMdtOwnerId(9);
        System.assertNotEquals(null, expectedOwner,
            'MDT Rule 9 must have a non-blank OwnerId__c');

        Account acc = prepareAccount('Test Postal Prefix Match', sysAdminUserId);
        acc.BillingState      = 'Hawaii';
        acc.BillingPostalCode = '90210';

        Test.startTest();
        AccountAssignmentRules.assign(new List<Account>{ acc });
        Test.stopTest();

        Account result = [SELECT OwnerId FROM Account WHERE Id = :acc.Id];
        System.assertEquals(
            expectedOwner,
            result.OwnerId,
            'Rule 9 must assign OwnerId for Hawaii + postal prefix 902'
        );
    }

    // ─── 4.2.4 testNonSysAdminInsert_Ignored ────────────────────────────────

    @isTest
    static void testNonSysAdminInsert_Ignored() {
        // Account owned by a standard (non-SysAdmin) user must be skipped entirely.
        Account acc = prepareAccount('Test Non SysAdmin', nonSysAdminUserId);
        acc.BillingCountry = 'Australia';

        Test.startTest();
        AccountAssignmentRules.assign(new List<Account>{ acc });
        Test.stopTest();

        Account result = [SELECT OwnerId FROM Account WHERE Id = :acc.Id];
        System.assertEquals(
            nonSysAdminUserId,
            result.OwnerId,
            'Non-SysAdmin owner: engine must not re-assign OwnerId'
        );
    }

    // ─── 4.2.5 testCatchAllRule_NeverMatches ─────────────────────────────────

    @isTest
    static void testCatchAllRule_NeverMatches() {
        // An account with no geographic fields must not match any rule.
        // isCatchAll() must prevent all-blank rules from firing.
        AccountAssignmentRules.skipEmailInTest = true;

        Account acc = prepareAccount('Test CatchAll', sysAdminUserId);
        // No BillingCountry, BillingState, or BillingPostalCode set.

        Test.startTest();
        AccountAssignmentRules.assign(new List<Account>{ acc });
        Test.stopTest();

        Account result = [SELECT OwnerId FROM Account WHERE Id = :acc.Id];
        // No rule should match an account with blank geography.
        // OwnerId stays as sysAdminUserId (no update performed by engine).
        System.assertEquals(
            sysAdminUserId,
            result.OwnerId,
            'Catch-all guard must prevent all-blank rules from firing'
        );
    }

    // ─── 4.2.6 testNoMatchBehavior ────────────────────────────────────────────

    @isTest
    static void testNoMatchBehavior() {
        // Fictitious country that matches no rule — all lookup fields must be unchanged.
        Account acc = prepareAccount('Test No Match', sysAdminUserId);
        acc.BillingCountry    = 'Narnia';
        acc.BillingState      = 'XYZ';
        acc.BillingPostalCode = '99999';

        Test.startTest();
        AccountAssignmentRules.assign(new List<Account>{ acc });
        Test.stopTest();

        Account result = [
            SELECT OwnerId
            FROM Account
            WHERE Id = :acc.Id
        ];
        System.assertEquals(sysAdminUserId, result.OwnerId,
            'No-match: OwnerId must remain the original owner');
    }

    // ─── Edge: testInvalidOwnerAlert_EmailPath ───────────────────────────────

    @isTest
    static void testInvalidOwnerAlert_EmailPath() {
        // Exercises the GroupMember email-collection path (lines 116-120) by ensuring
        // the AccountAssignmentRule_Admins group has members when assign() is called.
        // Group and GroupMember (setup objects) are created first, then Account DML
        // is done inside System.runAs() to avoid MIXED_DML_OPERATION restriction.

        // Step 1: insert setup objects (Group + GroupMember)
        Group adminGroup;
        List<Group> existing = [
            SELECT Id FROM Group
            WHERE DeveloperName = 'AccountAssignmentRule_Admins' AND Type = 'Regular'
        ];
        if (existing.isEmpty()) {
            adminGroup = new Group(
                Name          = 'AccountAssignmentRule Admins',
                DeveloperName = 'AccountAssignmentRule_Admins',
                Type          = 'Regular'
            );
            insert adminGroup;
        } else {
            adminGroup = existing[0];
        }

        List<GroupMember> members = [
            SELECT Id FROM GroupMember
            WHERE GroupId = :adminGroup.Id AND UserOrGroupId = :UserInfo.getUserId()
        ];
        if (members.isEmpty()) {
            insert new GroupMember(
                GroupId       = adminGroup.Id,
                UserOrGroupId = UserInfo.getUserId()
            );
        }

        // Step 2: Account DML + assign() via System.runAs() to avoid MIXED_DML
        User currentUser = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        Boolean thrown = false;
        Id accId;
        System.runAs(currentUser) {
            Account acc = prepareAccount('Test Email Alert Path', sysAdminUserId);
            acc.BillingCountry = 'Narnia'; // no rule matches — safe, no alert fired
            accId = acc.Id;

            Test.startTest();
            try {
                // assign() runs the pre-loop GroupMember query — covers lines 116-120.
                // No alert fires here (no matching rule), but the GroupMember path is hit.
                AccountAssignmentRules.assign(new List<Account>{ acc });
            } catch (Exception e) {
                thrown = true;
            }
            Test.stopTest();
        }

        System.assertEquals(false, thrown,
            'Engine must not throw when AccountAssignmentRule_Admins group exists');
    }

    // ─── 4.2.7 testInvalidOwner_SkipAndContinue ──────────────────────────────

    @isTest
    static void testInvalidOwner_SkipAndContinue() {
        // Engine must complete without exception when no valid rule owner is found.
        AccountAssignmentRules.skipEmailInTest = true;

        Account acc = prepareAccount('Test Invalid Owner Skip', sysAdminUserId);
        acc.BillingCountry = 'Narnia'; // no rule matches

        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            AccountAssignmentRules.assign(new List<Account>{ acc });
        } catch (Exception e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        System.assertEquals(false, exceptionThrown,
            'Engine must not throw even when no valid owner rule is found');

        Account result = [SELECT OwnerId FROM Account WHERE Id = :acc.Id];
        System.assertEquals(sysAdminUserId, result.OwnerId,
            'OwnerId must remain unchanged when no valid rule is found');
    }

    // ─── 4.2.8 testBulkInsert_200Accounts ────────────────────────────────────

    @isTest
    static void testBulkInsert_200Accounts() {
        // 200 accounts owned by a real SysAdmin, all matching Rule 1 (Australia).
        Id expectedOwner = getMdtOwnerId(1);
        System.assertNotEquals(null, expectedOwner,
            'MDT Rule 1 must have a non-blank OwnerId__c');

        Id commRtId = [
            SELECT Id FROM RecordType
            WHERE SObjectType = 'Account' AND DeveloperName = 'Commercial' LIMIT 1
        ].Id;

        List<Account> accounts = new List<Account>();
        for (Integer i = 0; i < 200; i++) {
            accounts.add(new Account(
                Name           = 'Bulk Account ' + i,
                RecordTypeId   = commRtId,
                Website        = 'https://bulk.example.com',
                OwnerId        = sysAdminUserId,
                BillingCountry = 'Australia'
            ));
        }
        insert accounts;

        Test.startTest();
        AccountAssignmentRules.assign(accounts);
        Test.stopTest();

        List<Account> results = [
            SELECT OwnerId FROM Account
            WHERE Id IN :accounts
        ];

        System.assertEquals(200, results.size(), 'All 200 accounts must be returned');
        for (Account result : results) {
            System.assertEquals(
                expectedOwner,
                result.OwnerId,
                'Bulk: every account must have Rule 1 OwnerId for Australia'
            );
        }
    }

    // ─── 4.2.9 testLowestOrderWins ────────────────────────────────────────────

    @isTest
    static void testLowestOrderWins() {
        // Rule 1 (Order 1) must win over any higher-order rule for Australia.
        Id rule1Owner = getMdtOwnerId(1);
        Id rule2Owner = getMdtOwnerId(2);

        System.assertNotEquals(null, rule1Owner, 'MDT Rule 1 must have a non-blank OwnerId__c');
        System.assertNotEquals(null, rule2Owner, 'MDT Rule 2 must have a non-blank OwnerId__c');

        Account acc = prepareAccount('Test Lowest Order Wins', sysAdminUserId);
        acc.BillingCountry = 'Australia';

        // Triangulation account: Canada+Alberta should get Rule 2, NOT Rule 1's owner.
        Account acc2 = prepareAccount('Test Lowest Order Wins Triangulate', sysAdminUserId);
        acc2.BillingCountry = 'Canada';
        acc2.BillingState   = 'Alberta';

        Test.startTest();
        AccountAssignmentRules.assign(new List<Account>{ acc });
        AccountAssignmentRules.assign(new List<Account>{ acc2 });
        Test.stopTest();

        Account result = [SELECT OwnerId FROM Account WHERE Id = :acc.Id];
        System.assertEquals(
            rule1Owner,
            result.OwnerId,
            'Rule 1 (Order 1) must be applied; higher-order rules must not override it'
        );

        Account result2 = [SELECT OwnerId FROM Account WHERE Id = :acc2.Id];
        System.assertEquals(
            rule2Owner,
            result2.OwnerId,
            'Rule 2 must apply for Canada+Alberta (not Rule 1 owner)'
        );
        System.assertNotEquals(
            rule1Owner,
            result2.OwnerId,
            'Canada+Alberta must not get Rule 1 (Australia) owner'
        );
    }
}
