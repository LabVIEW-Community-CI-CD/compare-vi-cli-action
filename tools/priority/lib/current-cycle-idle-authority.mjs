export const DEFAULT_IDLE_AUTHORITY_FRESH_SECONDS = 6 * 60 * 60;

function asOptional(value) {
  if (value == null) {
    return null;
  }
  const normalized = String(value).trim();
  return normalized.length > 0 ? normalized : null;
}

function parseDate(value) {
  if (!value || typeof value !== 'string') {
    return null;
  }
  const parsed = Date.parse(value);
  if (!Number.isFinite(parsed)) {
    return null;
  }
  return new Date(parsed);
}

function newestDate(...values) {
  const dates = values
    .filter((value) => value instanceof Date && !Number.isNaN(value.getTime()))
    .sort((left, right) => right.getTime() - left.getTime());
  return dates[0] || null;
}

function toIso(value) {
  if (!(value instanceof Date) || Number.isNaN(value.getTime())) {
    return null;
  }
  return value.toISOString();
}

function ageSeconds(referenceDate, now) {
  if (!(referenceDate instanceof Date) || Number.isNaN(referenceDate.getTime())) {
    return null;
  }
  return Math.max(0, Math.round((now.getTime() - referenceDate.getTime()) / 1000));
}

function normalizeDeliveryIdleSignal(deliveryRuntimeState, now, freshnessThresholdSeconds) {
  const payload = deliveryRuntimeState && typeof deliveryRuntimeState === 'object' ? deliveryRuntimeState : null;
  const activeLane = payload?.activeLane && typeof payload.activeLane === 'object' ? payload.activeLane : null;
  const observedAt = newestDate(
    parseDate(payload?.generatedAt),
    parseDate(activeLane?.generatedAt),
    parseDate(payload?.lifecycle?.updatedAt)
  );
  const age = ageSeconds(observedAt, now);
  const fresh = age !== null ? age <= freshnessThresholdSeconds : false;
  const queueEmpty =
    payload?.derivedFromQueueEmptyState === true ||
    asOptional(payload?.queueState?.status) === 'queue-empty' ||
    asOptional(payload?.queueState?.reason) === 'queue-empty' ||
    asOptional(activeLane?.outcome) === 'queue-empty' ||
    asOptional(activeLane?.reason) === 'queue-empty' ||
    asOptional(activeLane?.actionType) === 'monitoring-idle' ||
    asOptional(activeLane?.laneId) === 'queue-empty-monitoring';
  const idle =
    asOptional(payload?.status) === 'idle' &&
    asOptional(payload?.laneLifecycle) === 'idle';

  return {
    observedAt,
    ageSeconds: age,
    fresh,
    qualifies: Boolean(queueEmpty && idle),
    nextWakeCondition: asOptional(activeLane?.nextWakeCondition),
    syntheticIdle: payload?.derivedFromQueueEmptyState === true || activeLane?.syntheticIdle === true
  };
}

function normalizeObserverIdleSignal(observerHeartbeat, now, freshnessThresholdSeconds) {
  const payload = observerHeartbeat && typeof observerHeartbeat === 'object' ? observerHeartbeat : null;
  const activeLane = payload?.activeLane && typeof payload.activeLane === 'object' ? payload.activeLane : null;
  const executionDetails =
    activeLane?.execution?.details && typeof activeLane.execution.details === 'object'
      ? activeLane.execution.details
      : null;
  const observedAt = newestDate(
    parseDate(payload?.generatedAt),
    parseDate(activeLane?.generatedAt),
    parseDate(activeLane?.execution?.generatedAt)
  );
  const age = ageSeconds(observedAt, now);
  const fresh = age !== null ? age <= freshnessThresholdSeconds : false;
  const queueEmpty =
    asOptional(payload?.outcome) === 'queue-empty' ||
    asOptional(executionDetails?.actionType) === 'monitoring-idle' ||
    asOptional(executionDetails?.laneLifecycle) === 'idle' && asOptional(executionDetails?.blockerClass) === 'none' && activeLane == null;
  const idle =
    asOptional(payload?.outcome) === 'queue-empty' ||
    activeLane == null ||
    asOptional(executionDetails?.laneLifecycle) === 'idle';

  return {
    observedAt,
    ageSeconds: age,
    fresh,
    qualifies: Boolean(queueEmpty && idle),
    nextWakeCondition: asOptional(activeLane?.nextWakeCondition) || asOptional(executionDetails?.nextWakeCondition),
    syntheticIdle: activeLane == null
  };
}

export function deriveCurrentCycleIdleAuthority({
  deliveryRuntimeState = null,
  observerHeartbeat = null,
  now = new Date(),
  freshnessThresholdSeconds = DEFAULT_IDLE_AUTHORITY_FRESH_SECONDS
} = {}) {
  const delivery = normalizeDeliveryIdleSignal(deliveryRuntimeState, now, freshnessThresholdSeconds);
  const observer = normalizeObserverIdleSignal(observerHeartbeat, now, freshnessThresholdSeconds);
  const deliveryObserved = delivery.qualifies && delivery.fresh;
  const observerObserved = observer.qualifies && observer.fresh;

  let status = 'missing';
  let source = null;
  if (deliveryObserved && observerObserved) {
    status = 'observed';
    source = 'delivery-and-observer';
  } else if (deliveryObserved) {
    status = 'observed';
    source = 'delivery-agent-state';
  } else if (observerObserved) {
    status = 'observed';
    source = 'observer-heartbeat';
  }

  return {
    status,
    source,
    observedAt: toIso(newestDate(deliveryObserved ? delivery.observedAt : null, observerObserved ? observer.observedAt : null)),
    fresh: status === 'observed',
    freshnessThresholdSeconds,
    nextWakeCondition:
      (deliveryObserved ? delivery.nextWakeCondition : null) ||
      (observerObserved ? observer.nextWakeCondition : null),
    syntheticIdle: delivery.syntheticIdle || observer.syntheticIdle,
    queueState: status === 'observed' ? 'queue-empty' : null,
    deliveryStateObservedAt: toIso(delivery.observedAt),
    deliveryStateFresh: delivery.fresh,
    observerHeartbeatObservedAt: toIso(observer.observedAt),
    observerHeartbeatFresh: observer.fresh
  };
}
