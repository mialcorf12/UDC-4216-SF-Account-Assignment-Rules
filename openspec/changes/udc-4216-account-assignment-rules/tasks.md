# Tasks: UDC-4216 SF Account Assignment Rules

## Review Workload Forecast

| Field | Value |
|-------|-------|
| Estimated changed lines | ~750–950 lines |
| 400-line budget risk | High |
| Chained PRs recommended | Yes |
| Suggested split | PR 1 → MDT metadata + 5 fields + VR + 18 records · PR 2 → AccountAssignmentRules engine + test · PR 3 → AccountTrigger wiring + final verification |
| Delivery strategy | auto-chain |
| Chain strategy | stacked-to-main |

Decision needed before apply: No
Chained PRs recommended: Yes
Chain strategy: stacked-to-main
400-line budget risk: High

### Suggested Work Units

| Unit | Goal | Likely PR | Focused test command | Runtime harness | Rollback boundary |
|------|------|-----------|----------------------|-----------------|-------------------|
| 1 | MDT object + 5 fields + Require_Owner VR + 18 custom metadata records | PR 1 | `sf project deploy start -d force-app/main/default/objects/Account_Assignment_Rule__mdt -d force-app/main/default/customMetadata -o Dev` | Deploy MDT to Dev org and verify records appear in Setup → Custom Metadata Types | Delete MDT definition + records; zero impact on Apex or trigger |
| 2 | AccountAssignmentRules.cls + AccountAssignmentRulesTest.cls (full TDD cycle) | PR 2 | `sf apex run test -n AccountAssignmentRulesTest -o Dev --code-coverage` | Run test suite in Dev org; assert ≥ 85% coverage | Delete both cls files; trigger still routes to original handler only |
| 3 | AccountTrigger (retrieve + modify) + AccountTriggerHandler (retrieve) + final deploy | PR 3 | `sf apex run test -n AccountAssignmentRulesTest -o Dev --code-coverage` | Insert Account as SysAdmin in Dev org and verify OwnerId changes per MDT rules | Revert trigger to retrieved baseline; AccountAssignmentRules class remains inert |

---

## Phase 1: Prerequisites (Manual + Retrieval)

- [ ] 1.1 **[PENDING — ORG SETUP]** Create Public Group `AccountAssignmentRule Admins` in Setup; confirm DeveloperName = `AccountAssignmentRule_Admins`; add Alberto Cordero as member.
- [x] 1.2 Retrieve `AccountTrigger` + `AccountTriggerHandler` from Dev org: `sf project retrieve start -m "ApexClass:AccountTriggerHandler" -m "ApexTrigger:AccountTrigger" -o Dev`
- [x] 1.3 Verify retrieved files exist at `force-app/main/default/triggers/AccountTrigger.trigger` and `force-app/main/default/classes/AccountTriggerHandler.cls`; committed as-is (no logic changes).
- [x] 1.4 Retrieve flow `Company_Integration_Specialist_Assignment` from Dev org for documentation; no modification required.

## Phase 2: MDT Definition + Fields + Validation Rule (PR 1)

- [x] 2.1 Create `Account_Assignment_Rule__mdt.object-meta.xml` with label, pluralLabel, visibility=Public.
- [x] 2.2 Create `Order__c.field-meta.xml` — Number(2,0), required.
- [x] 2.3 Create `BillingCountry__c.field-meta.xml` — Text(255), not required.
- [x] 2.4 Create `BillingState__c.field-meta.xml` — Text(255), not required.
- [x] 2.5 Create `BillingPostalCode__c.field-meta.xml` — LongTextArea(32768), not required.
- [x] 2.6 Create `OwnerId__c.field-meta.xml` — Text(18), not required (stores User Id as string).
- [x] ~~2.7 Create `Integration_Specialist__c.field-meta.xml`~~ — **REMOVED**: specialist assignment delegated to flow.
- [x] ~~2.8 Create `Development_Specialist__c.field-meta.xml`~~ — **REMOVED**: specialist assignment delegated to flow.
- [x] 2.7 Create `Require_Owner.validationRule-meta.xml` — error if `OwnerId__c` is blank.
- [x] 2.8 Deploy MDT definition: `sf project deploy start -d force-app/main/default/objects/Account_Assignment_Rule__mdt -o Dev` → Succeeded

## Phase 3: MDT Records (18 staging records) — still PR 1

- [x] 3.1 Created all 18 `Account_Assignment_Rule__mdt.Rule_*.md-meta.xml` files under `force-app/main/default/customMetadata/` (Rule_1 through Rule_18).
- [x] 3.2 Deploy records: `sf project deploy start -d force-app/main/default/customMetadata -o Dev` → Succeeded
- [x] 3.3 Verify records visible in Setup → Custom Metadata Types → Account Assignment Rule → Manage Records.
- [x] 3.4 Post-refactor: removed `Integration_Specialist__c` and `Development_Specialist__c` field values from all 13 records that had them populated. Commit: `9097d42`.
- [x] 3.5 Several OwnerId values updated in subsequent commit: `159209d`.
- [x] 3.6 Final deploy to staging: commit `a4a8219`.

## Phase 4: RED Tests (PR 2)

- [x] 4.1 Create `AccountAssignmentRulesTest.cls-meta.xml` (API v67.0).
- [x] 4.2 Write `AccountAssignmentRulesTest.cls` with all test methods — RED phase (commit `9161e5d`):
  - [x] 4.2.1 `testSysAdminInsert_CountryMatch()` — SysAdmin user inserts Account with matching country; assert OwnerId changed.
  - [x] 4.2.2 `testSysAdminInsert_CountryStateMatch()` — assert OwnerId set.
  - [x] 4.2.3 `testSysAdminInsert_PostalCodePrefix()` — BillingPostalCode startsWith match; assert OwnerId.
  - [x] 4.2.4 `testNonSysAdminInsert_Ignored()` — assert OwnerId unchanged.
  - [x] 4.2.5 `testCatchAllRule_NeverMatches()` — rule with blank Country/State/Postal; assert no assignment.
  - [x] 4.2.6 `testNoMatchBehavior()` — no rule matches; assert fields unchanged.
  - [x] 4.2.7 `testInvalidOwner_SkipAndContinue()` — inactive user OwnerId; assert rule skipped; email suppressed via `skipEmailInTest = true`.
  - [x] 4.2.8 `testBulkInsert_200Accounts()` — 200 Account inserts; assert all 200 assigned correctly.
  - [x] 4.2.9 `testLowestOrderWins()` — two rules with different countries; assert correct rule applied per Account.
  - [x] 4.2.10 `testEmptyAndNullInput()` — null and empty list; assert no exception.
  - [x] 4.2.11 `testSendInvalidOwnerAlert_Direct()` — exercises all three sendInvalidOwnerAlert paths directly.
  - [x] 4.2.12 `testInvalidOwnerAlert_EmailPath()` — exercises GroupMember email-collection path.

## Phase 5: GREEN Implementation (PR 2)

- [x] 5.1 Create `AccountAssignmentRules.cls-meta.xml` (API v67.0, `with sharing`).
- [x] 5.2 Implement `AccountAssignmentRules.cls` per contract (commit `d4bc416`):
  - [x] 5.2.1 `public static void assign(List<Account> newAccounts)` — profile filter, MDT query, owner Map, GroupMember query, processing loop, single DML.
  - [x] 5.2.2 `isCatchAll()` guard + `matches()` per rule (AND logic, blank=wildcard).
  - [x] 5.2.3 Stage updates as `new Account(Id=acc.Id, OwnerId=x)` — avoids Trigger.new read-only FinalException.
  - [x] 5.2.4 Single `update List<Account>` DML after loop.
  - [x] 5.2.5 `@TestVisible static Boolean skipEmailInTest = false`.
  - [x] 5.2.6 `@TestVisible private static void sendInvalidOwnerAlert(String ruleOrder, String ownerId, List<String> alertEmails)`.
  - [x] 5.2.7 Debug logs in Spanish: `se aplico la regla #[Order__c]`, `no cumplio con ninguna regla establecida`, `regla #[Order] fallida — OwnerId inválido: [Id]`.
- [x] 5.3 Post-refactor: removed all specialist field logic from engine (commit `9097d42`). Engine assigns OwnerId only.
- [x] 5.4 All 12 tests PASS — 91% coverage (≥85% requirement met).

## Phase 6: AccountTrigger Wiring (PR 3)

- [x] 6.1 Modify `AccountTrigger.trigger`: `after insert` → `AccountAssignmentRules.assign(Trigger.new)`; `after update` → `AccountTriggerHandler.handleDynamicUpdate(Trigger.new, Trigger.oldMap)`.
- [x] 6.2 Fixed FinalException (Record is read-only) — changed to `new Account(Id=acc.Id)` pattern.
- [x] 6.3 Deploy trigger + engine fix → Succeeded. Commit: `fcbd70c`.
- [x] 6.4 Re-run full test suite — 12/12 PASS, 91% coverage.

## Phase 7: Final Verification

- [x] 7.1 Anonymous Apex smoke test — Account with BillingCountry=Australia → OwnerId Match: true.
- [x] 7.2 Deploy to staging — commit `a4a8219`.
- [ ] 7.3 **[PENDING]** Create Public Group `AccountAssignmentRule Admins` (DeveloperName: `AccountAssignmentRule_Admins`) in Setup; add Alberto Cordero as member.
- [ ] 7.4 **[PENDING]** Validate all 18 MDT records with real Account data in sandbox.
- [ ] 7.5 **[PENDING]** Confirm flow `Company_Integration_Specialist_Assignment` fires correctly after OwnerId assignment and populates specialist fields.
- [ ] 7.6 **[PENDING]** PO sign-off and deploy to production.
