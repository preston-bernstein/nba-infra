# Kafka notes

Plain facts about what was built. For interviews.

## What I built

- A single-broker Kafka (KRaft, no ZooKeeper) in `docker-compose.yml`, with a job that creates the topics.
- `nba-data-service` (Go) publishes `game.updated` when a game is new or its status or score changes. Key is the game id. Library: franz-go.
- `nba-analytics-hub/api` (Node) consumes it in group `bff`. It keeps a live-games read model and serves it over SSE at `GET /games/stream`. Library: kafkajs.
- `nba-predictor` (Python) consumes it in group `predictor`. It stores a prediction per game, then records the outcome when the game is final. Library: confluent-kafka.
- Both consumers dedupe on event id, retry transient errors with backoff, and send bad messages to `game.updated.dlq`. Offsets are committed after processing.
- Each repo has an integration test against the compose broker: duplicate applied once, bad message in the DLQ, restart resumes from the committed offset.

## One problem I hit

franz-go compresses batches with Snappy by default. kafkajs cannot read Snappy and its consumer crashed with `KafkaJSNotImplemented: Snappy compression not implemented`. The unit and integration tests did not catch it, because the Node tests wrote with kafkajs. A smoke run (Go container into the broker, Node consumer reading) did. Fix: the Go producer now uses gzip, and a test pins the codec.

## What I did not do

- No cluster operations. One broker, replication factor 1, no auth, no TLS.
- No schema registry. The contract is one JSON Schema file, copied into each repo.
- No outbox. The Go service publishes straight from the poller, so a crash between a snapshot write and a publish can lose an event.
- In the local smoke run both fixture games went to the DLQ in the predictor (unknown team, not enough history). The "stores a prediction" path is covered by unit tests, not by that run.
- No metrics for Kafka failures in the Go service. Failures are logged.

## Honest CV wording

Built an event-driven pipeline on Kafka (producer, consumer groups, partitioning by key, DLQ, idempotent consumers) across Go, Node, and Python services in a personal project. Hands-on in a project, not production cluster operations.
