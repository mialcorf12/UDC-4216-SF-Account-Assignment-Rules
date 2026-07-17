# Specification: UDC-4216 SF Account Assignment Rules

**What**: SDD Spec for UDC-4216 Account Assignment Rules
**Why**: Define clear behavior and test scenarios for the assignment engine before design.
**Learned**: Defined 8 core requirements with 11 scenarios covering profile restrictions, geographic criteria, and fallback handling. Specialist assignment removed from engine scope — delegated to existing flow.

## Purpose
Metadata-driven Account assignment engine automating OwnerId assignment based on geographic criteria for SysAdmin inserts. Integration Specialist and Development Specialist assignment is handled by the existing flow `Company_Integration_Specialist_Assignment` which fires automatically when OwnerId changes.

## Requirements

### Requirement: Profile Filter
The system MUST process Account inserts ONLY from 'uLab SysAdmin' or 'System Administrator' profiles.
#### Scenario: SysAdmin insert
- GIVEN the inserting user has the profile 'System Administrator'
- WHEN an Account is inserted
- THEN the system evaluates the assignment rules
#### Scenario: Non-SysAdmin insert
- GIVEN the inserting user has a standard profile
- WHEN an Account is inserted
- THEN the system ignores the record silently

### Requirement: Rule Evaluation Order
The system SHALL evaluate active `Account_Assignment_Rule__mdt` records in ascending `Order__c` and stop at the first match.
#### Scenario: Lowest order wins
- GIVEN an Account matches rules with Order 10 and 20
- WHEN the system evaluates rules
- THEN the rule with Order 10 is applied and evaluation halts

### Requirement: Catch-All Skipping
The system MUST skip rules where Country, State, and Postal Code are all blank.
#### Scenario: Catch-all prevention
- GIVEN a rule has all geographic criteria blank
- WHEN evaluation occurs
- THEN the rule matches no Accounts

### Requirement: Geographic Matching (AND logic)
The system MUST match ALL non-blank geographic criteria case-insensitively. Blank criteria act as wildcards. Postal Code matches via `startsWith`. Country and State are comma-separated lists. ALL non-blank criteria must pass — AND logic.
#### Scenario: Country only match
- GIVEN a rule specifies Country only (State and Postal blank)
- WHEN an Account's BillingCountry matches any value in the comma-separated list
- THEN the rule matches
#### Scenario: Country and State match
- GIVEN a rule specifies Country and State (Postal blank)
- WHEN an Account matches both criteria case-insensitively
- THEN the rule matches
#### Scenario: Country, State, and Postal Code prefix
- GIVEN a rule specifies Country, State, and Postal Code prefix '902'
- WHEN an Account's BillingCountry and BillingState match AND BillingPostalCode starts with '902'
- THEN the rule matches
#### Scenario: Partial match does not apply
- GIVEN a rule specifies Country and State
- WHEN an Account matches Country but NOT State
- THEN the rule does not match and evaluation continues

### Requirement: OwnerId Assignment
The system MUST update `OwnerId` upon match.
#### Scenario: Rule application
- GIVEN a matching rule
- WHEN the system assigns the owner
- THEN Account.OwnerId is updated to OwnerId__c
- AND debug log "se aplico la regla #[Order__c]" is emitted

### Requirement: Specialist Assignment (Delegated)
Integration Specialist and Development Specialist assignment is OUT OF SCOPE for the engine. The existing flow `Company_Integration_Specialist_Assignment` handles this automatically when OwnerId changes on a uLab Account.
#### Scenario: Specialist fields populated by flow
- GIVEN AccountAssignmentRules sets OwnerId on a uLab Account
- WHEN the RecordAfterSave flow fires (OwnerId IsChanged)
- THEN the flow reads Integration_Specialist__c and Development_Specialist__c from the new Owner's User record
- AND populates those fields on the Account

### Requirement: No Match Behavior
The system SHALL NOT modify fields if no rule matches.
#### Scenario: No rules match
- GIVEN no geographic criteria match an Account
- WHEN evaluation concludes
- THEN no fields change
- AND debug log "no cumplio con ninguna regla establecida" is emitted

### Requirement: Invalid Owner Fallback
The system MUST skip matches where `OwnerId__c` resolves to an inactive/invalid user, log an error, email 'AccountAssignmentRule Admins', and proceed to the next rule.
#### Scenario: Inactive Owner
- GIVEN a matching rule has an inactive OwnerId
- WHEN applied
- THEN the rule is skipped
- AND error "regla #[Order__c] fallida — OwnerId inválido: [Id]" is logged
- AND an alert email is sent to the Admins group (DeveloperName: AccountAssignmentRule_Admins)
- AND evaluation continues to the next matching rule

### Requirement: Bulkification and Limits
The system MUST support bulk operations without SOQL inside loops and execute final updates in a single DML.
#### Scenario: Bulk limits
- GIVEN 200+ Account inserts
- WHEN processed
- THEN all MDT queries occur before loops
- AND final Account updates happen in one DML
- AND transaction CPU time is < 8000ms
