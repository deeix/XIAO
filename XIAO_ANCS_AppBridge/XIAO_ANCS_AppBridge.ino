/*********************************************************************
 XIAO Notify firmware for Seeed Studio XIAO nRF52840.
 Receives iOS notifications through ANCS and forwards newline-delimited
 UTF-8 JSON to the XIAO Notify companion app.
*********************************************************************/

#include <bluefruit.h>

BLEAncs bleancs;

BLEService bridgeService("6E400001-B5A3-F393-E0A9-E50E24DCCA9E");
BLECharacteristic bridgeRx("6E400002-B5A3-F393-E0A9-E50E24DCCA9E");
BLECharacteristic bridgeTx("6E400003-B5A3-F393-E0A9-E50E24DCCA9E");

static const uint8_t PROTOCOL_VERSION = 2;
static const char FIRMWARE_VERSION[] = "1.2.0";
static const size_t ATTRIBUTE_SIZE = 256;
static const size_t JSON_SIZE = 2560;
static const size_t CHUNK_SIZE = 180;
static const uint8_t TX_QUEUE_DEPTH = 6;
static const uint8_t RELIABLE_QUEUE_CAPACITY = 32;
static const uint32_t RELIABLE_RETRY_MS = 2000;
static const uint8_t ANCS_DISCOVERY_MAX_ATTEMPTS = 5;
static const uint32_t ANCS_DISCOVERY_RETRY_MS = 1500;
static const uint32_t PAIRING_TIMEOUT_MS = 15000;
static const uint32_t ADVERTISING_WATCHDOG_GRACE_MS = 10000;
static const uint32_t ADVERTISING_RESET_TIMEOUT_MS = 30000;

enum LinkState : uint8_t {
  LINK_BOOT,
  LINK_ADVERTISING,
  LINK_CONNECTED,
  LINK_DISCOVERING_ANCS,
  LINK_PAIRING,
  LINK_READY
};

struct TxFrame {
  uint16_t length;
  char data[JSON_SIZE];
};

struct ReliableFrame {
  bool used;
  bool transmitted;
  uint32_t sequence;
  uint32_t lastSentAt;
  char sessionId[18];
  TxFrame frame;
};

char jsonBuffer[JSON_SIZE];
char appIdBuffer[ATTRIBUTE_SIZE];
char appNameBuffer[ATTRIBUTE_SIZE];
char titleBuffer[ATTRIBUTE_SIZE];
char messageBuffer[ATTRIBUTE_SIZE];
char escapedIdBuffer[ATTRIBUTE_SIZE * 2];
char escapedNameBuffer[ATTRIBUTE_SIZE * 2];
char escapedTitleBuffer[ATTRIBUTE_SIZE * 2];
char escapedMessageBuffer[ATTRIBUTE_SIZE * 2];
TxFrame txStaging;
TxFrame txCurrent;
ReliableFrame reliableFrames[RELIABLE_QUEUE_CAPACITY];
uint32_t forwardedCount = 0;
uint32_t droppedCount = 0;
uint32_t acknowledgedCount = 0;
uint32_t reconnectCount = 0;
uint32_t nextSequence = 1;
uint32_t sessionCounter = 0;
uint8_t reliablePending = 0;
char sessionId[18] = "legacy";
char lastError[96] = "";
uint32_t lastErrorAt = 0;
bool ancsReady = false;
bool appSubscribed = false;
bool statusLedOn = false;
uint32_t lastLedChange = 0;
uint32_t nextAncsDiscoveryAt = 0;
uint32_t stateChangedAt = 0;
uint32_t advertisingFailureSince = 0;
uint16_t activeConnHandle = BLE_CONN_HANDLE_INVALID;
uint8_t ancsDiscoveryAttempts = 0;
bool advertisingRecoveryAttempted = false;
bool streamNeedsResync = false;
volatile LinkState linkState = LINK_BOOT;
QueueHandle_t txQueue = NULL;
SemaphoreHandle_t reliableMutex = NULL;

const char* EVENT_NAMES[] = { "Added", "Modified", "Removed" };
const char* CATEGORY_NAMES[] = {
  "Other", "Incoming Call", "Missed Call", "Voice Mail", "Social",
  "Schedule", "Email", "News", "Health and Fitness",
  "Business and Finance", "Location", "Entertainment"
};

void startAdvertising();
void sendStatus(const char* event, const char* detail = "");
void sendLog(const char* level, const char* event, const char* detail = "");
bool sendFrame(const char* text);
bool enqueueReliable(const char* text, uint32_t sequence, const char* frameSession);
bool transmitFrame(const TxFrame& frame);
bool ensureStreamAligned();
void processReliableQueue();
void acknowledgeReliable(const char* frameSession, uint32_t sequence);
void markReliableForRetry();
void generateSessionId();
void setLastError(const char* error);
void sanitizeUtf8(char* text);
void setStatusLed(bool on);
void bootHeartbeat();
void serviceConnectionState();
void serviceAdvertisingWatchdog();
void processTxQueue();
bool enableAncs(uint16_t connHandle);
bool containsIgnoreCase(const char* text, const char* needle);
const char* linkStateName(LinkState state);
void forceModuleReset(const char* reason);
void pairingCompleteCallback(uint16_t connHandle, uint8_t authStatus);
const char* disconnectReasonName(uint8_t reason);

void setup() {
  pinMode(LED_BUILTIN, OUTPUT);
  setStatusLed(false);
  bootHeartbeat();

  Serial.begin(115200);
  delay(50);
  Serial.print("XIAO Notify ");
  Serial.print(FIRMWARE_VERSION);
  Serial.println(" reliable protocol v2");

  txQueue = xQueueCreate(TX_QUEUE_DEPTH, sizeof(TxFrame));
  reliableMutex = xSemaphoreCreateMutex();
  if (!txQueue || !reliableMutex) {
    Serial.println("FATAL: queue allocation failed");
    forceModuleReset("queue_allocation_failed");
  }

  Bluefruit.configServiceChanged(true);
  Bluefruit.configPrphBandwidth(BANDWIDTH_MAX);
  Bluefruit.begin();
  Bluefruit.autoConnLed(false);
  // Keep the name short: the scan response has a strict 31-byte limit.
  Bluefruit.setName("XIAO Notify");
  Bluefruit.setTxPower(4);
  Bluefruit.Periph.setConnIntervalMS(15, 30);
  Bluefruit.Periph.setConnSlaveLatency(0);
  Bluefruit.Periph.setConnSupervisionTimeoutMS(4000);
  Bluefruit.Periph.setConnectCallback(connectCallback);
  Bluefruit.Periph.setDisconnectCallback(disconnectCallback);
  Bluefruit.Security.setIOCaps(false, false, false);
  Bluefruit.Security.setMITM(false);
  Bluefruit.Security.setSecuredCallback(securedCallback);
  Bluefruit.Security.setPairCompleteCallback(pairingCompleteCallback);

  bleancs.begin();
  bleancs.setNotificationCallback(ancsNotificationCallback);

  bridgeService.begin();

  bridgeRx.setProperties(CHR_PROPS_WRITE | CHR_PROPS_WRITE_WO_RESP);
  bridgeRx.setPermission(SECMODE_OPEN, SECMODE_OPEN);
  bridgeRx.setMaxLen(128);
  bridgeRx.setWriteCallback(rxCallback);
  bridgeRx.begin();

  bridgeTx.setProperties(CHR_PROPS_NOTIFY);
  bridgeTx.setPermission(SECMODE_OPEN, SECMODE_NO_ACCESS);
  bridgeTx.setMaxLen(244);
  bridgeTx.setCccdWriteCallback(cccdCallback);
  bridgeTx.begin();

  startAdvertising();
}

void loop() {
  serviceConnectionState();
  serviceAdvertisingWatchdog();
  processReliableQueue();
  processTxQueue();
  updateStatusLed();
  delay(5);
}

void startAdvertising() {
  Bluefruit.Advertising.clearData();
  Bluefruit.ScanResponse.clearData();
  Bluefruit.Advertising.addFlags(BLE_GAP_ADV_FLAGS_LE_ONLY_GENERAL_DISC_MODE);
  Bluefruit.Advertising.addTxPower();

  // Keep this identical to the proven Bluefruit ANCS example. ANCS uses a
  // 128-bit solicitation UUID; adding another UUID can make the advertisement
  // invisible on iOS by overflowing the strict 31-byte packet limit.
  Bluefruit.Advertising.addService(bleancs);
  Bluefruit.ScanResponse.addName();
  Bluefruit.Advertising.restartOnDisconnect(true);
  Bluefruit.Advertising.setInterval(32, 244);
  Bluefruit.Advertising.setFastTimeout(30);
  const bool started = Bluefruit.Advertising.start(0);
  if (started) {
    linkState = LINK_ADVERTISING;
    advertisingFailureSince = 0;
    advertisingRecoveryAttempted = false;
    Serial.println("Advertising started (20 ms -> 152.5 ms)");
  } else {
    advertisingFailureSince = millis();
    Serial.println("ERROR: advertising start failed");
  }
}

void updateStatusLed() {
  if (linkState == LINK_READY) {
    statusLedOn = false;
    setStatusLed(false);
    return;
  }

  // Slow blink while available, fast blink while connecting/discovering.
  const uint32_t interval = (linkState == LINK_ADVERTISING) ? 500 : 120;
  const uint32_t now = millis();
  if (now - lastLedChange >= interval) {
    lastLedChange = now;
    statusLedOn = !statusLedOn;
    setStatusLed(statusLedOn);
  }
}

void connectCallback(uint16_t connHandle) {
  ancsReady = false;
  appSubscribed = false;
  activeConnHandle = connHandle;
  ancsDiscoveryAttempts = 0;
  nextAncsDiscoveryAt = millis() + 250;
  linkState = LINK_CONNECTED;
  stateChangedAt = millis();
  advertisingFailureSince = 0;
  advertisingRecoveryAttempted = false;
  reconnectCount++;
  generateSessionId();
  streamNeedsResync = false;
  if (txQueue) xQueueReset(txQueue);
  Serial.println("iPhone connected; ANCS discovery scheduled");
}

void securedCallback(uint16_t connHandle) {
  BLEConnection* connection = Bluefruit.Connection(connHandle);
  if (!connection) {
    Serial.println("Security callback without an active connection");
    return;
  }
  if (!connection->secured()) {
    Serial.println("Security not established; requesting pairing");
    linkState = LINK_PAIRING;
    stateChangedAt = millis();
    if (!connection->requestPairing()) connection->disconnect();
    return;
  }

  enableAncs(connHandle);
}

void disconnectCallback(uint16_t connHandle, uint8_t reason) {
  (void)connHandle;
  ancsReady = false;
  appSubscribed = false;
  activeConnHandle = BLE_CONN_HANDLE_INVALID;
  linkState = LINK_ADVERTISING;
  advertisingFailureSince = 0;
  advertisingRecoveryAttempted = false;
  lastLedChange = 0;
  statusLedOn = false;
  setStatusLed(false);
  streamNeedsResync = false;
  setLastError(disconnectReasonName(reason));
  Serial.print("Disconnected: 0x");
  Serial.print(reason, HEX);
  Serial.print(" ");
  Serial.println(disconnectReasonName(reason));
}

void cccdCallback(uint16_t connHandle, BLECharacteristic* characteristic, uint16_t value) {
  (void)connHandle;
  (void)characteristic;
  appSubscribed = value != 0;
  if (appSubscribed) {
    Serial.println("Companion subscribed");
    markReliableForRetry();
    sendStatus("bridge_ready", "XIAO Notify subscribed");
  } else {
    Serial.println("Companion unsubscribed");
  }
}

void rxCallback(uint16_t connHandle, BLECharacteristic* characteristic, uint8_t* data, uint16_t len) {
  (void)connHandle;
  (void)characteristic;
  char command[129] = {0};
  len = min((uint16_t)128, len);
  memcpy(command, data, len);

  if (strstr(command, "\"command\":\"ack\"") || strstr(command, "\"command\": \"ack\"")) {
    const char* seqField = strstr(command, "\"seq\":");
    const char* sessionField = strstr(command, "\"session_id\":\"");
    if (seqField && sessionField) {
      const uint32_t sequence = strtoul(seqField + 6, NULL, 10);
      sessionField += 14;
      char ackSession[18] = {0};
      const char* end = strchr(sessionField, '"');
      if (end) {
        const size_t count = min((size_t)(end - sessionField), sizeof(ackSession) - 1);
        memcpy(ackSession, sessionField, count);
        acknowledgeReliable(ackSession, sequence);
      }
    }
  } else if (strstr(command, "status") || strstr(command, "hello")) {
    sendStatus("snapshot", ancsReady ? "ANCS ready" : "Waiting for ANCS");
  } else {
    sendLog("warning", "unknown_command", command);
  }
}

void ancsNotificationCallback(AncsNotification_t* notification) {
  if (notification->eventID > ANCS_EVT_NOTIFICATION_REMOVED) return;

  const char* eventName = EVENT_NAMES[notification->eventID];
  const char* category = categoryName(notification->categoryID);

  // Removed events frequently have no readable attributes. UID is enough for
  // the app to update the existing record without creating a blank duplicate.
  if (notification->eventID == ANCS_EVT_NOTIFICATION_REMOVED) {
    const uint32_t sequence = nextSequence++;
    snprintf(jsonBuffer, sizeof(jsonBuffer),
      "{\"v\":%u,\"type\":\"notification\",\"session_id\":\"%s\",\"seq\":%lu,\"uid\":%lu,\"event\":\"Removed\",\"category\":\"%s\",\"received_ms\":%lu}",
      PROTOCOL_VERSION, sessionId, sequence, notification->uid, category, millis());
    enqueueReliable(jsonBuffer, sequence, sessionId);
    return;
  }

  memset(appIdBuffer, 0, sizeof(appIdBuffer));
  memset(appNameBuffer, 0, sizeof(appNameBuffer));
  memset(titleBuffer, 0, sizeof(titleBuffer));
  memset(messageBuffer, 0, sizeof(messageBuffer));
  memset(escapedIdBuffer, 0, sizeof(escapedIdBuffer));
  memset(escapedNameBuffer, 0, sizeof(escapedNameBuffer));
  memset(escapedTitleBuffer, 0, sizeof(escapedTitleBuffer));
  memset(escapedMessageBuffer, 0, sizeof(escapedMessageBuffer));

  bleancs.getAppID(notification->uid, appIdBuffer, sizeof(appIdBuffer));
  bleancs.getAppAttribute(appIdBuffer, ANCS_APP_ATTR_DISPLAY_NAME, appNameBuffer, sizeof(appNameBuffer));
  bleancs.getTitle(notification->uid, titleBuffer, sizeof(titleBuffer));
  bleancs.getMessage(notification->uid, messageBuffer, sizeof(messageBuffer));
  sanitizeUtf8(appIdBuffer);
  sanitizeUtf8(appNameBuffer);
  sanitizeUtf8(titleBuffer);
  sanitizeUtf8(messageBuffer);
  removeBidiMarks(titleBuffer);
  removeBidiMarks(messageBuffer);

  jsonEscape(appIdBuffer, escapedIdBuffer, sizeof(escapedIdBuffer));
  jsonEscape(appNameBuffer, escapedNameBuffer, sizeof(escapedNameBuffer));
  jsonEscape(titleBuffer, escapedTitleBuffer, sizeof(escapedTitleBuffer));
  jsonEscape(messageBuffer, escapedMessageBuffer, sizeof(escapedMessageBuffer));
  const char* source = classifySource(appIdBuffer, appNameBuffer);

  const uint32_t sequence = nextSequence++;
  snprintf(jsonBuffer, sizeof(jsonBuffer),
    "{\"v\":%u,\"type\":\"notification\",\"session_id\":\"%s\",\"seq\":%lu,\"uid\":%lu,\"event\":\"%s\",\"source\":\"%s\",\"app_id\":\"%s\",\"app\":\"%s\",\"category\":\"%s\",\"title\":\"%s\",\"message\":\"%s\",\"received_ms\":%lu}",
    PROTOCOL_VERSION, sessionId, sequence, notification->uid, eventName, source, escapedIdBuffer,
    escapedNameBuffer, category, escapedTitleBuffer, escapedMessageBuffer, millis());

  enqueueReliable(jsonBuffer, sequence, sessionId);
}

bool sendFrame(const char* text) {
  if (!text || !text[0] || !txQueue) return false;
  const size_t length = strnlen(text, JSON_SIZE - 2);
  txStaging.length = (uint16_t)(length + 1);
  memcpy(txStaging.data, text, length);
  txStaging.data[length] = '\n';
  txStaging.data[length + 1] = 0;
  if (xQueueSend(txQueue, &txStaging, 0) != pdTRUE) {
    Serial.println("TX queue full; frame dropped");
    return false;
  }
  return true;
}

bool enqueueReliable(const char* text, uint32_t sequence, const char* frameSession) {
  if (!text || !text[0] || !reliableMutex) return false;
  if (xSemaphoreTake(reliableMutex, pdMS_TO_TICKS(100)) != pdTRUE) {
    droppedCount++;
    setLastError("reliable_queue_lock_timeout");
    return false;
  }

  ReliableFrame* slot = NULL;
  for (uint8_t i = 0; i < RELIABLE_QUEUE_CAPACITY; i++) {
    if (!reliableFrames[i].used) {
      slot = &reliableFrames[i];
      break;
    }
  }

  if (!slot) {
    xSemaphoreGive(reliableMutex);
    droppedCount++;
    setLastError("reliable_queue_full");
    Serial.println("Reliable queue full; notification dropped");
    return false;
  }

  memset(slot, 0, sizeof(*slot));
  const size_t length = strnlen(text, JSON_SIZE - 2);
  slot->used = true;
  slot->sequence = sequence;
  slot->frame.length = (uint16_t)(length + 1);
  strncpy(slot->sessionId, frameSession, sizeof(slot->sessionId) - 1);
  memcpy(slot->frame.data, text, length);
  slot->frame.data[length] = '\n';
  slot->frame.data[length + 1] = 0;
  reliablePending++;
  xSemaphoreGive(reliableMutex);
  return true;
}

bool transmitFrame(const TxFrame& frame) {
  const size_t length = min((size_t)frame.length, JSON_SIZE);
  for (size_t offset = 0; offset < length; offset += CHUNK_SIZE) {
    const size_t part = min(CHUNK_SIZE, length - offset);
    if (!bridgeTx.notify((const uint8_t*)frame.data + offset, part)) return false;
  }
  return true;
}

bool ensureStreamAligned() {
  if (!streamNeedsResync) return true;
  static const uint8_t delimiter = '\n';
  if (!bridgeTx.notify(&delimiter, 1)) return false;
  streamNeedsResync = false;
  return true;
}

void processReliableQueue() {
  if (!reliableMutex || !Bluefruit.connected() || !appSubscribed) return;
  if (xSemaphoreTake(reliableMutex, 0) != pdTRUE) return;

  ReliableFrame* selected = NULL;
  const uint32_t now = millis();
  for (uint8_t i = 0; i < RELIABLE_QUEUE_CAPACITY; i++) {
    ReliableFrame& candidate = reliableFrames[i];
    if (!candidate.used) continue;
    if (!selected || candidate.sequence < selected->sequence) selected = &candidate;
  }

  // Keep a single frame in flight. This guarantees ordering and means an ACK
  // loss can only retransmit the current frame, never roll back a newer event.
  if (selected && (!selected->lastSentAt || now - selected->lastSentAt >= RELIABLE_RETRY_MS)) {
    selected->lastSentAt = now ? now : 1;
    if (ensureStreamAligned() && transmitFrame(selected->frame)) {
      if (!selected->transmitted) {
        selected->transmitted = true;
        forwardedCount++;
      }
    } else {
      streamNeedsResync = true;
      setLastError("reliable_notify_failed");
      Serial.println("Reliable TX failed; retained for retry");
    }
  }
  xSemaphoreGive(reliableMutex);
}

void acknowledgeReliable(const char* frameSession, uint32_t sequence) {
  if (!reliableMutex || !frameSession || !frameSession[0]) return;
  if (xSemaphoreTake(reliableMutex, pdMS_TO_TICKS(100)) != pdTRUE) return;
  for (uint8_t i = 0; i < RELIABLE_QUEUE_CAPACITY; i++) {
    ReliableFrame& frame = reliableFrames[i];
    if (frame.used && frame.sequence == sequence && strcmp(frame.sessionId, frameSession) == 0) {
      frame.used = false;
      if (reliablePending) reliablePending--;
      acknowledgedCount++;
      break;
    }
  }
  xSemaphoreGive(reliableMutex);
}

void markReliableForRetry() {
  if (!reliableMutex || xSemaphoreTake(reliableMutex, pdMS_TO_TICKS(100)) != pdTRUE) return;
  for (uint8_t i = 0; i < RELIABLE_QUEUE_CAPACITY; i++) {
    if (reliableFrames[i].used) reliableFrames[i].lastSentAt = 0;
  }
  xSemaphoreGive(reliableMutex);
}

void generateSessionId() {
  uint32_t nonce = 0;
  const uint32_t result = sd_rand_application_vector_get((uint8_t*)&nonce, sizeof(nonce));
  if (result != NRF_SUCCESS) nonce = NRF_FICR->DEVICEID[0] ^ millis() ^ sessionCounter;
  sessionCounter++;
  snprintf(sessionId, sizeof(sessionId), "%08lX-%lu", nonce, sessionCounter);
}

void setLastError(const char* error) {
  if (!error) error = "";
  strncpy(lastError, error, sizeof(lastError) - 1);
  lastError[sizeof(lastError) - 1] = 0;
  lastErrorAt = error[0] ? millis() : 0;
}

void sendStatus(const char* event, const char* detail) {
  char escaped[192] = {0};
  char escapedError[192] = {0};
  jsonEscape(detail, escaped, sizeof(escaped));
  jsonEscape(lastError, escapedError, sizeof(escapedError));
  snprintf(jsonBuffer, sizeof(jsonBuffer),
    "{\"v\":%u,\"type\":\"status\",\"event\":\"%s\",\"detail\":\"%s\",\"firmware_version\":\"%s\",\"state\":\"%s\",\"session_id\":\"%s\",\"ancs_ready\":%s,\"subscribed\":%s,\"forwarded\":%lu,\"acked\":%lu,\"dropped\":%lu,\"queue_pending\":%u,\"queue_capacity\":%u,\"reconnects\":%lu,\"ancs_attempts\":%u,\"last_error\":\"%s\",\"last_error_ms\":%lu,\"uptime_ms\":%lu}",
    PROTOCOL_VERSION, event, escaped, FIRMWARE_VERSION, linkStateName(linkState), sessionId,
    ancsReady ? "true" : "false", appSubscribed ? "true" : "false",
    forwardedCount, acknowledgedCount, droppedCount, reliablePending, RELIABLE_QUEUE_CAPACITY,
    reconnectCount, ancsDiscoveryAttempts, escapedError, lastErrorAt, millis());
  sendFrame(jsonBuffer);
}

void sendLog(const char* level, const char* event, const char* detail) {
  char escaped[256] = {0};
  jsonEscape(detail, escaped, sizeof(escaped));
  snprintf(jsonBuffer, sizeof(jsonBuffer),
    "{\"v\":%u,\"type\":\"log\",\"level\":\"%s\",\"event\":\"%s\",\"detail\":\"%s\",\"uptime_ms\":%lu}",
    PROTOCOL_VERSION, level, event, escaped, millis());
  sendFrame(jsonBuffer);
}

const char* classifySource(const char* appId, const char* appName) {
  if (containsIgnoreCase(appId, "simple") || containsIgnoreCase(appName, "simple")) return "simple";
  if (containsIgnoreCase(appId, "binance") || containsIgnoreCase(appName, "binance")) return "binance";
  if (containsIgnoreCase(appId, "bybit") || containsIgnoreCase(appName, "bybit")) return "bybit";
  if (containsIgnoreCase(appId, "okx") || containsIgnoreCase(appName, "okx") ||
      containsIgnoreCase(appId, "okex") || containsIgnoreCase(appName, "okex")) return "okx";
  return "other";
}

bool containsIgnoreCase(const char* text, const char* needle) {
  if (!text || !needle || !needle[0]) return false;
  const size_t needleLength = strlen(needle);
  for (size_t i = 0; text[i]; i++) {
    size_t j = 0;
    while (j < needleLength && text[i + j] &&
           tolower((unsigned char)text[i + j]) == tolower((unsigned char)needle[j])) {
      j++;
    }
    if (j == needleLength) return true;
  }
  return false;
}

const char* categoryName(uint8_t id) {
  if (id < sizeof(CATEGORY_NAMES) / sizeof(CATEGORY_NAMES[0])) return CATEGORY_NAMES[id];
  return "Unknown";
}

void removeBidiMarks(char* text) {
  if (!text) return;
  const uint8_t marks[][3] = {{0xE2, 0x80, 0xAD}, {0xE2, 0x80, 0xAC},
                              {0xE2, 0x80, 0x8E}, {0xE2, 0x80, 0x8F}};
  size_t length = strlen(text);
  for (size_t mark = 0; mark < 4; mark++) {
    for (size_t i = 0; i + 2 < length;) {
      if (memcmp(text + i, marks[mark], 3) == 0) {
        memmove(text + i, text + i + 3, length - i - 2);
        length -= 3;
      } else i++;
    }
  }
}

void sanitizeUtf8(char* text) {
  if (!text) return;
  size_t read = 0;
  size_t write = 0;
  while (text[read]) {
    const uint8_t lead = (uint8_t)text[read];
    uint8_t length = 0;
    if (lead < 0x80) length = 1;
    else if (lead >= 0xC2 && lead <= 0xDF) length = 2;
    else if (lead >= 0xE0 && lead <= 0xEF) length = 3;
    else if (lead >= 0xF0 && lead <= 0xF4) length = 4;

    bool valid = length != 0;
    for (uint8_t i = 1; valid && i < length; i++) {
      const uint8_t continuation = (uint8_t)text[read + i];
      if (!continuation || (continuation & 0xC0) != 0x80) valid = false;
    }

    if (!valid) {
      // An incomplete sequence at the end is truncated; other invalid bytes
      // are replaced so the complete JSON frame remains valid UTF-8.
      if (length > 1 && !text[read + 1]) break;
      text[write++] = '?';
      read++;
      continue;
    }

    for (uint8_t i = 0; i < length; i++) text[write++] = text[read++];
  }
  text[write] = 0;
}

void jsonEscape(const char* input, char* output, size_t outputSize) {
  if (!outputSize) return;
  size_t out = 0;
  for (size_t i = 0; input && input[i] && out + 1 < outputSize; i++) {
    uint8_t c = input[i];
    if ((c == '"' || c == '\\') && out + 2 < outputSize) {
      output[out++] = '\\'; output[out++] = c;
    } else if (c == '\n' || c == '\r' || c == '\t') {
      if (out + 2 >= outputSize) break;
      output[out++] = '\\'; output[out++] = c == '\n' ? 'n' : (c == '\r' ? 'r' : 't');
    } else if (c < 0x20) {
      output[out++] = ' ';
    } else output[out++] = c;
  }
  output[out] = 0;
}

void setStatusLed(bool on) {
  // XIAO nRF52840 RGB LED is common-anode (active LOW). The Seeeduino
  // 1.1.13 variant incorrectly declares LED_STATE_ON as HIGH, so using that
  // macro leaves the red channel continuously lit when it should be off.
  digitalWrite(LED_BUILTIN, on ? LOW : HIGH);
}

void bootHeartbeat() {
  for (uint8_t i = 0; i < 3; i++) {
    setStatusLed(true);
    delay(80);
    setStatusLed(false);
    delay(80);
  }
}

bool enableAncs(uint16_t connHandle) {
  if (ancsReady && linkState == LINK_READY) return true;
  BLEConnection* connection = Bluefruit.Connection(connHandle);
  if (!connection || !connection->connected() || !connection->secured()) return false;

  if (bleancs.discovered() && bleancs.enableNotification()) {
    ancsReady = true;
    linkState = LINK_READY;
    stateChangedAt = millis();
    Serial.println("ANCS ready; notifications enabled");
    sendStatus("ancs_ready", "Notifications enabled");
    return true;
  }

  ancsReady = false;
  linkState = LINK_DISCOVERING_ANCS;
  nextAncsDiscoveryAt = millis() + ANCS_DISCOVERY_RETRY_MS;
  sendLog("error", "ancs_enable_failed", "Could not enable ANCS notifications");
  return false;
}

void serviceConnectionState() {
  if (!Bluefruit.connected() || activeConnHandle == BLE_CONN_HANDLE_INVALID) return;
  if (linkState == LINK_READY) return;

  if (linkState == LINK_PAIRING) {
    if (millis() - stateChangedAt >= PAIRING_TIMEOUT_MS) {
      Serial.println("Pairing timeout; reconnecting cleanly");
      BLEConnection* connection = Bluefruit.Connection(activeConnHandle);
      if (connection) connection->disconnect();
    }
    return;
  }

  const uint32_t now = millis();
  if (now < nextAncsDiscoveryAt) return;

  BLEConnection* connection = Bluefruit.Connection(activeConnHandle);
  if (!connection || !connection->connected()) return;

  linkState = LINK_DISCOVERING_ANCS;
  ancsDiscoveryAttempts++;
  Serial.print("ANCS discovery attempt ");
  Serial.print(ancsDiscoveryAttempts);
  Serial.print("/");
  Serial.println(ANCS_DISCOVERY_MAX_ATTEMPTS);

  if (bleancs.discover(activeConnHandle)) {
    Serial.println("ANCS discovered");
    if (connection->secured()) {
      enableAncs(activeConnHandle);
    } else {
      linkState = LINK_PAIRING;
      stateChangedAt = millis();
      Serial.println("Requesting encrypted ANCS session");
      if (!connection->requestPairing()) {
        Serial.println("Pairing request failed; disconnecting");
        connection->disconnect();
      }
    }
    return;
  }

  Serial.println("ANCS discovery failed");
  if (ancsDiscoveryAttempts >= ANCS_DISCOVERY_MAX_ATTEMPTS) {
    Serial.println("ANCS unavailable after retries; reconnecting cleanly");
    sendLog("error", "ancs_discovery_exhausted", "Disconnecting for a clean ANCS session");
    connection->disconnect();
    return;
  }

  nextAncsDiscoveryAt = now + ANCS_DISCOVERY_RETRY_MS;
}

void serviceAdvertisingWatchdog() {
  if (Bluefruit.connected()) {
    advertisingFailureSince = 0;
    advertisingRecoveryAttempted = false;
    return;
  }

  if (Bluefruit.Advertising.isRunning()) {
    linkState = LINK_ADVERTISING;
    advertisingFailureSince = 0;
    advertisingRecoveryAttempted = false;
    return;
  }

  const uint32_t now = millis();
  if (!advertisingFailureSince) advertisingFailureSince = now;
  const uint32_t failedFor = now - advertisingFailureSince;

  if (!advertisingRecoveryAttempted && failedFor >= ADVERTISING_WATCHDOG_GRACE_MS) {
    advertisingRecoveryAttempted = true;
    Serial.println("Watchdog: advertising absent for 10 s; one restart attempt");
    if (Bluefruit.Advertising.start(0)) {
      linkState = LINK_ADVERTISING;
      advertisingFailureSince = 0;
      advertisingRecoveryAttempted = false;
      Serial.println("Watchdog: advertising restored");
      return;
    }
    Serial.println("Watchdog: advertising restart failed");
  }

  if (failedFor >= ADVERTISING_RESET_TIMEOUT_MS) {
    forceModuleReset("advertising_absent_30s");
  }
}

void processTxQueue() {
  if (!txQueue || !Bluefruit.connected() || !appSubscribed) return;

  if (xQueueReceive(txQueue, &txCurrent, 0) != pdTRUE) return;

  if (!ensureStreamAligned() || !transmitFrame(txCurrent)) {
    streamNeedsResync = true;
    droppedCount++;
    setLastError("best_effort_notify_failed");
    Serial.println("TX notify failed; frame dropped");
  }
}

const char* linkStateName(LinkState state) {
  switch (state) {
    case LINK_BOOT: return "boot";
    case LINK_ADVERTISING: return "advertising";
    case LINK_CONNECTED: return "connected";
    case LINK_DISCOVERING_ANCS: return "discovering_ancs";
    case LINK_PAIRING: return "pairing";
    case LINK_READY: return "ready";
    default: return "unknown";
  }
}

void pairingCompleteCallback(uint16_t connHandle, uint8_t authStatus) {
  Serial.print("Pairing complete: 0x");
  Serial.println(authStatus, HEX);
  BLEConnection* connection = Bluefruit.Connection(connHandle);
  if (authStatus == BLE_GAP_SEC_STATUS_SUCCESS && connection && connection->secured()) {
    enableAncs(connHandle);
  } else if (authStatus != BLE_GAP_SEC_STATUS_SUCCESS) {
    Serial.println("Pairing rejected; disconnecting to resume advertising");
    if (connection) connection->disconnect();
  }
}

void forceModuleReset(const char* reason) {
  Serial.print("Fatal recovery reset: ");
  Serial.println(reason);
  for (uint8_t i = 0; i < 5; i++) {
    setStatusLed(true);
    delay(70);
    setStatusLed(false);
    delay(70);
  }
  NVIC_SystemReset();
}

const char* disconnectReasonName(uint8_t reason) {
  switch (reason) {
    case BLE_HCI_REMOTE_USER_TERMINATED_CONNECTION: return "remote_user_terminated";
    case BLE_HCI_REMOTE_DEV_TERMINATION_DUE_TO_LOW_RESOURCES: return "remote_low_resources";
    case BLE_HCI_REMOTE_DEV_TERMINATION_DUE_TO_POWER_OFF: return "remote_power_off";
    case BLE_HCI_CONN_INTERVAL_UNACCEPTABLE: return "conn_interval_unacceptable";
    case BLE_HCI_CONN_TERMINATED_DUE_TO_MIC_FAILURE: return "mic_failure";
    case BLE_HCI_STATUS_CODE_PIN_OR_KEY_MISSING: return "pin_or_key_missing";
    case BLE_HCI_PAIRING_WITH_UNIT_KEY_UNSUPPORTED: return "pairing_unit_key_unsupported";
    case BLE_HCI_STATUS_CODE_LMP_ERROR_TRANSACTION_COLLISION: return "transaction_collision";
    case BLE_HCI_STATUS_CODE_COMMAND_DISALLOWED: return "command_disallowed";
    case BLE_HCI_STATUS_CODE_UNSPECIFIED_ERROR: return "unspecified_error";
    default: return "unknown";
  }
}
