## MODIFIED Requirements

### Requirement: Question card dismiss behavior
When the user dismisses (ignores) a question card, the system MUST close the card UI without sending any response to the AI tool. The continuation MUST NOT be resumed. The dismissed session ID MUST be recorded for tracking purposes.

#### Scenario: Dismiss AskUserQuestion card without replying to AI
- **WHEN** user clicks "Dismiss" (Ignore) button on an AskUserQuestion card
- **THEN** the question card UI closes
- **AND** no response is sent to the AI tool (continuation is not resumed)
- **AND** the session ID is added to `dismissedQuestionSessionIds`
- **AND** surface transitions to `.collapsed` or next pending item

#### Scenario: Dismiss legacy notification question card
- **WHEN** user clicks "Dismiss" button on a notification-style question card
- **THEN** the question card UI closes
- **AND** no response is sent to the AI tool (continuation is not resumed)
- **AND** surface transitions to `.collapsed` or next pending item

#### Scenario: Skip button still sends deny response
- **WHEN** user clicks "Skip" button on any question card
- **THEN** the system sends a deny/empty response to the AI tool
- **AND** behavior remains unchanged from current implementation

#### Scenario: Dismissed question followed by peer disconnect
- **WHEN** a question was dismissed by user (no response sent)
- **AND** the bridge socket disconnects for the same session
- **THEN** `drainQuestions` handles any remaining questions in the queue
- **AND** dismissed question's continuation remains un-resumed (already removed from queue)

#### Scenario: Show next pending after dismiss
- **WHEN** user dismisses a question card
- **AND** there is another question in the queue
- **THEN** the next question card is shown
- **AND** surface transitions to `.questionCard(sessionId:)`
