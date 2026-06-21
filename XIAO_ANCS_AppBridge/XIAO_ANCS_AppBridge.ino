/*********************************************************************
 XIAO Notify firmware for Seeed Studio XIAO nRF52840.
 Receives iOS notifications through ANCS and forwards newline-delimited
 UTF-8 JSON to the XIAO Notify companion app.
*********************************************************************/

#include <bluefruit.h>

BLEClientDis bleClientDis;
BLEAncs bleancs;

BLEService bridgeService("6E400001-B5A3-F393-E0A9-E50E24DCCA9E");
BLECharacteristic bridgeRx("6E400002-B5A3-F393-E0A9-E50E24DCCA9E");
BLECharacteristic bridgeTx("6E400003-B5A3-F393-E0A9-E50E24DCCA9E");

static const uint8_t PROTOCOL_VERSION = 1;
static const size_t ATTRIBUTE_SIZE = 256;
static const size_t JSON_SIZE = 2560;
static const size_t CHUNK_SIZE = 180;

char jsonBuffer[JSON_SIZE];
uint32_t forwardedCount = 0;
uint32_t droppedCount = 0;
bool ancsReady = false;
bool appSubscribed = false;

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

void setup() {
  Serial.begin(115200);
  delay(50);
  Serial.println("XIAO Notify 1.0.0");

  Bluefruit.configPrphBandwidth(BANDWIDTH_MAX);
  Bluefruit.begin();
  Bluefruit.setName("XIAO Notify Bridge");
  Bluefruit.setTxPower(4);
  Bluefruit.Periph.setConnectCallback(connectCallback);
  Bluefruit.Periph.setDisconnectCallback(disconnectCallback);
  Bluefruit.Security.setSecuredCallback(securedCallback);

  bleClientDis.begin();
  bleancs.begin();
  bleancs.setNotificationCallback(ancsNotificationCallback);

  bridgeService.begin();

  bridgeRx.setProperties(CHR_PROPS_WRITE | CHR_PROPS_WRITE_WO_RESP);
  bridgeRx.setPermission(SECMODE_OPEN, SECMODE_OPEN);
  bridgeRx.setMaxLen(64);
  bridgeRx.setWriteCallback(rxCallback);
  bridgeRx.begin();

  bridgeTx.setProperties(CHR_PROPS_NOTIFY);
  bridgeTx.setPermission(SECMODE_OPEN, SECMODE_NO_ACCESS);
  bridgeTx.setMaxLen(244);
  bridgeTx.setCccdWriteCallback(cccdCallback);
  bridgeTx.begin();

  startAdvertising();
  Serial.println("Advertising started");
}

void loop() {
  delay(20);
}

void startAdvertising() {
  Bluefruit.Advertising.addFlags(BLE_GAP_ADV_FLAGS_LE_ONLY_GENERAL_DISC_MODE);
  Bluefruit.Advertising.addTxPower();
  Bluefruit.Advertising.addService(bleancs);
  Bluefruit.Advertising.addService(bridgeService);
  Bluefruit.ScanResponse.addName();
  Bluefruit.Advertising.restartOnDisconnect(true);
  Bluefruit.Advertising.setInterval(32, 244);
  Bluefruit.Advertising.setFastTimeout(30);
  Bluefruit.Advertising.start(0);
}

void connectCallback(uint16_t connHandle) {
  BLEConnection* connection = Bluefruit.Connection(connHandle);
  ancsReady = false;
  appSubscribed = false;
  Serial.println("iPhone connected; discovering ANCS");

  bleClientDis.discover(connHandle);
  if (bleancs.discover(connHandle)) {
    connection->requestPairing();
  } else {
    Serial.println("ANCS discovery failed");
  }
}

void securedCallback(uint16_t connHandle) {
  BLEConnection* connection = Bluefruit.Connection(connHandle);
  if (!connection->secured()) {
    connection->requestPairing();
    return;
  }

  if (bleancs.discovered() && bleancs.enableNotification()) {
    ancsReady = true;
    Serial.println("ANCS ready");
    sendStatus("ancs_ready", "Notifications enabled");
  } else {
    sendLog("error", "ancs_enable_failed", "Could not enable ANCS notifications");
  }
}

void disconnectCallback(uint16_t connHandle, uint8_t reason) {
  (void)connHandle;
  ancsReady = false;
  appSubscribed = false;
  Serial.print("Disconnected: 0x");
  Serial.println(reason, HEX);
}

void cccdCallback(uint16_t connHandle, BLECharacteristic* characteristic, uint16_t value) {
  (void)connHandle;
  (void)characteristic;
  appSubscribed = value != 0;
  if (appSubscribed) {
    Serial.println("Companion subscribed");
    sendStatus("bridge_ready", "XIAO Notify subscribed");
  } else {
    Serial.println("Companion unsubscribed");
  }
}

void rxCallback(uint16_t connHandle, BLECharacteristic* characteristic, uint8_t* data, uint16_t len) {
  (void)connHandle;
  (void)characteristic;
  char command[65] = {0};
  len = min((uint16_t)64, len);
  memcpy(command, data, len);

  if (strstr(command, "status") || strstr(command, "hello")) {
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
    snprintf(jsonBuffer, sizeof(jsonBuffer),
      "{\"v\":%u,\"type\":\"notification\",\"uid\":%lu,\"event\":\"Removed\",\"category\":\"%s\",\"received_ms\":%lu}",
      PROTOCOL_VERSION, notification->uid, category, millis());
    if (sendFrame(jsonBuffer)) forwardedCount++; else droppedCount++;
    return;
  }

  char appId[ATTRIBUTE_SIZE] = {0};
  char appName[ATTRIBUTE_SIZE] = {0};
  char title[ATTRIBUTE_SIZE] = {0};
  char message[ATTRIBUTE_SIZE] = {0};
  char escapedId[ATTRIBUTE_SIZE * 2] = {0};
  char escapedName[ATTRIBUTE_SIZE * 2] = {0};
  char escapedTitle[ATTRIBUTE_SIZE * 2] = {0};
  char escapedMessage[ATTRIBUTE_SIZE * 2] = {0};

  bleancs.getAppID(notification->uid, appId, sizeof(appId));
  bleancs.getAppAttribute(appId, ANCS_APP_ATTR_DISPLAY_NAME, appName, sizeof(appName));
  bleancs.getTitle(notification->uid, title, sizeof(title));
  bleancs.getMessage(notification->uid, message, sizeof(message));
  removeBidiMarks(title);
  removeBidiMarks(message);

  jsonEscape(appId, escapedId, sizeof(escapedId));
  jsonEscape(appName, escapedName, sizeof(escapedName));
  jsonEscape(title, escapedTitle, sizeof(escapedTitle));
  jsonEscape(message, escapedMessage, sizeof(escapedMessage));
  const char* source = classifySource(appId, appName);

  snprintf(jsonBuffer, sizeof(jsonBuffer),
    "{\"v\":%u,\"type\":\"notification\",\"uid\":%lu,\"event\":\"%s\",\"source\":\"%s\",\"app_id\":\"%s\",\"app\":\"%s\",\"category\":\"%s\",\"title\":\"%s\",\"message\":\"%s\",\"received_ms\":%lu}",
    PROTOCOL_VERSION, notification->uid, eventName, source, escapedId,
    escapedName, category, escapedTitle, escapedMessage, millis());

  if (sendFrame(jsonBuffer)) forwardedCount++; else droppedCount++;
}

bool sendFrame(const char* text) {
  if (!Bluefruit.connected() || !appSubscribed || !text || !text[0]) return false;
  size_t length = strlen(text);
  for (size_t offset = 0; offset < length; offset += CHUNK_SIZE) {
    size_t part = min(CHUNK_SIZE, length - offset);
    if (!bridgeTx.notify((const uint8_t*)text + offset, part)) return false;
    delay(12);
  }
  const uint8_t newline = '\n';
  return bridgeTx.notify(&newline, 1);
}

void sendStatus(const char* event, const char* detail) {
  char escaped[192] = {0};
  jsonEscape(detail, escaped, sizeof(escaped));
  snprintf(jsonBuffer, sizeof(jsonBuffer),
    "{\"v\":%u,\"type\":\"status\",\"event\":\"%s\",\"detail\":\"%s\",\"ancs_ready\":%s,\"subscribed\":%s,\"forwarded\":%lu,\"dropped\":%lu,\"uptime_ms\":%lu}",
    PROTOCOL_VERSION, event, escaped, ancsReady ? "true" : "false",
    appSubscribed ? "true" : "false", forwardedCount, droppedCount, millis());
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
  String value = String(appId) + " " + String(appName);
  value.toLowerCase();
  if (value.indexOf("simple") >= 0 || value.indexOf("app.simple.com") >= 0) return "simple";
  if (value.indexOf("binance") >= 0) return "binance";
  if (value.indexOf("bybit") >= 0) return "bybit";
  if (value.indexOf("okx") >= 0 || value.indexOf("okex") >= 0) return "okx";
  return "other";
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
