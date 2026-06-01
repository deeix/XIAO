/*********************************************************************
 This sketch receives iOS ANCS notifications and forwards a compact
 JSON packet to the XIAO Companion iOS app through a custom BLE
 notify characteristic.
*********************************************************************/

#include <bluefruit.h>

// BLE Client Service
BLEClientDis bleClientDis;
BLEAncs      bleancs;

// Custom BLE service for the iOS companion app.
// The app scans/subscribes to notify characteristics and will show
// packets sent through xiaoNotifyChar in its log.
BLEService xiaoBridgeService("6E400001-B5A3-F393-E0A9-E50E24DCCA9E");
BLECharacteristic xiaoNotifyChar("6E400003-B5A3-F393-E0A9-E50E24DCCA9E");

#define BUFSIZE 128
char buffer[BUFSIZE];

#define JSON_BUFSIZE 384
char jsonBuffer[JSON_BUFSIZE];

const char* EVENT_STR[] = { "Added", "Modified", "Removed" };
const char* CAT_STR[] =
{
  "Other"             , "Incoming Call"       , "Missed Call", "Voice Mail"   ,
  "Social"            , "Schedule"            , "Email"      , "News"         ,
  "Health and Fitness", "Business and Finance", "Location"   , "Entertainment"
};

void setup()
{
  Serial.begin(115200);

  Serial.println("XIAO ANCS App Bridge");
  Serial.println("--------------------\n");

  Bluefruit.configPrphBandwidth(BANDWIDTH_MAX);

  Bluefruit.begin();
  Bluefruit.setName("XIAO ANCS Bridge");
  Bluefruit.setTxPower(4);
  Bluefruit.Periph.setConnectCallback(connect_callback);
  Bluefruit.Periph.setDisconnectCallback(disconnect_callback);

  Bluefruit.Security.setSecuredCallback(connection_secured_callback);

  bleClientDis.begin();

  bleancs.begin();
  bleancs.setNotificationCallback(ancs_notification_callback);

  setupXiaoBridgeService();
  startAdv();
}

void setupXiaoBridgeService()
{
  xiaoBridgeService.begin();

  xiaoNotifyChar.setProperties(CHR_PROPS_NOTIFY);
  xiaoNotifyChar.setPermission(SECMODE_OPEN, SECMODE_NO_ACCESS);
  xiaoNotifyChar.setMaxLen(244);
  xiaoNotifyChar.begin();
}

void startAdv(void)
{
  Bluefruit.Advertising.addFlags(BLE_GAP_ADV_FLAGS_LE_ONLY_GENERAL_DISC_MODE);
  Bluefruit.Advertising.addTxPower();

  Bluefruit.Advertising.addService(bleancs);
  Bluefruit.Advertising.addService(xiaoBridgeService);

  Bluefruit.ScanResponse.addName();

  Bluefruit.Advertising.restartOnDisconnect(true);
  Bluefruit.Advertising.setInterval(32, 244);
  Bluefruit.Advertising.setFastTimeout(30);
  Bluefruit.Advertising.start(0);
}

void loop()
{
  if (!Bluefruit.connected()) return;
  if (!bleancs.discovered()) return;
}

void connect_callback(uint16_t conn_handle)
{
  BLEConnection* conn = Bluefruit.Connection(conn_handle);

  Serial.println("Connected");
  sendToApp("{\"type\":\"status\",\"ble_connected\":true}");

  Serial.print("Discovering DIS ... ");
  if (bleClientDis.discover(conn_handle))
  {
    Serial.println("Discovered");

    memset(buffer, 0, BUFSIZE);
    if (bleClientDis.getManufacturer(buffer, BUFSIZE))
    {
      Serial.print("Manufacturer: ");
      Serial.println(buffer);
    }

    memset(buffer, 0, BUFSIZE);
    if (bleClientDis.getModel(buffer, BUFSIZE))
    {
      Serial.print("Model: ");
      Serial.println(buffer);
    }

    Serial.println();
  }

  Serial.print("Discovering ANCS ... ");
  if (bleancs.discover(conn_handle))
  {
    Serial.println("Discovered");
    Serial.print("Attempting to PAIR with the iOS device, please press PAIR on your phone ... ");
    conn->requestPairing();
  }
}

void connection_secured_callback(uint16_t conn_handle)
{
  BLEConnection* conn = Bluefruit.Connection(conn_handle);

  if (!conn->secured())
  {
    conn->requestPairing();
  }
  else
  {
    Serial.println("Secured");
    sendToApp("{\"type\":\"status\",\"secured\":true}");

    if (bleancs.discovered())
    {
      Serial.println("Enabling notifications");
      Serial.println();
      bleancs.enableNotification();
      sendToApp("{\"type\":\"status\",\"ancs_connected\":true}");
    }
  }
}

void ancs_notification_callback(AncsNotification_t* notif)
{
  uint32_t const uid = notif->uid;

  char appID[128] = { 0 };
  char appName[128] = { 0 };
  char title[128] = { 0 };
  char message[128] = { 0 };

  bleancs.getAppID(uid, appID, sizeof(appID));

  memset(buffer, 0, BUFSIZE);
  bleancs.getAppAttribute(appID, ANCS_APP_ATTR_DISPLAY_NAME, buffer, BUFSIZE);
  strncpy(appName, buffer, sizeof(appName) - 1);

  Serial.printf("%-15s (%s)\n", appName, appID);

  memset(buffer, 0, BUFSIZE);
  if (bleancs.getTitle(uid, buffer, BUFSIZE))
  {
    removeBidiMarks(buffer);
    strncpy(title, buffer, sizeof(title) - 1);
  }

  Serial.printf("%-15s %s\n", title, EVENT_STR[notif->eventID]);

  memset(buffer, 0, BUFSIZE);
  bleancs.getMessage(uid, buffer, BUFSIZE);
  strncpy(message, buffer, sizeof(message) - 1);
  Serial.printf("  %s\n", message);
  Serial.println();

  char escapedApp[128];
  char escapedTitle[128];
  char escapedMessage[128];

  jsonEscape(appName, escapedApp, sizeof(escapedApp));
  jsonEscape(title, escapedTitle, sizeof(escapedTitle));
  jsonEscape(message, escapedMessage, sizeof(escapedMessage));

  snprintf(jsonBuffer, sizeof(jsonBuffer),
           "{\"type\":\"notification\",\"uid\":%lu,\"event\":\"%s\",\"category\":\"%s\",\"app\":\"%s\",\"title\":\"%s\",\"message\":\"%s\"}",
           uid,
           EVENT_STR[notif->eventID],
           categoryName(notif->categoryID),
           escapedApp,
           escapedTitle,
           escapedMessage);

  sendToApp(jsonBuffer);

  // Keep/remove this block as you need. It auto-accepts incoming calls.
  if (notif->categoryID == ANCS_CAT_INCOMING_CALL && notif->eventID == ANCS_EVT_NOTIFICATION_ADDED)
  {
    Serial.println("Incoming call accepted");
    bleancs.performAction(notif->uid, ANCS_ACTION_POSITIVE);
  }
}

void disconnect_callback(uint16_t conn_handle, uint8_t reason)
{
  (void) conn_handle;

  Serial.println();
  Serial.print("Disconnected, reason = 0x");
  Serial.println(reason, HEX);
}

void sendToApp(const char* text)
{
  if (!Bluefruit.connected()) return;

  size_t len = strlen(text);
  if (len == 0) return;

  Serial.print("App bridge: ");
  Serial.println(text);

  // Keep each notify packet small enough for typical negotiated MTU.
  // The iOS app logs each packet immediately.
  const size_t chunkSize = 180;
  for (size_t offset = 0; offset < len; offset += chunkSize)
  {
    size_t partLen = min(chunkSize, len - offset);
    xiaoNotifyChar.notify((const uint8_t*) text + offset, partLen);
    delay(20);
  }
}

void removeBidiMarks(char* text)
{
  char u202D[3] = { 0xE2, 0x80, 0xAD };
  char u202C[3] = { 0xE2, 0x80, 0xAC };

  int len = strlen(text);

  if (len >= 3 && 0 == memcmp(&text[len - 3], u202C, 3))
  {
    len -= 3;
    text[len] = 0;
  }

  if (len >= 3 && 0 == memcmp(text, u202D, 3))
  {
    memmove(text, text + 3, len - 2);
  }
}

void jsonEscape(const char* input, char* output, size_t outputSize)
{
  if (outputSize == 0) return;

  size_t out = 0;
  for (size_t i = 0; input[i] != 0 && out + 1 < outputSize; i++)
  {
    char c = input[i];

    if ((c == '"' || c == '\\') && out + 2 < outputSize)
    {
      output[out++] = '\\';
      output[out++] = c;
    }
    else if ((uint8_t)c < 0x20)
    {
      output[out++] = ' ';
    }
    else
    {
      output[out++] = c;
    }
  }

  output[out] = 0;
}

const char* categoryName(uint8_t categoryID)
{
  if (categoryID < (sizeof(CAT_STR) / sizeof(CAT_STR[0])))
  {
    return CAT_STR[categoryID];
  }

  return "Unknown";
}
