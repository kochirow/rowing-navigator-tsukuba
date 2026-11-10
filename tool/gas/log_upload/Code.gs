/**
 * 練習ログの自動回収の受け口(Google Apps Script のウェブアプリ)。
 *
 * アプリ(lib/services/auto_log_upload_service.dart)が航行・監視の後に送る
 * 診断ZIPを、デプロイした人の Google ドライブへ保存する。
 *
 *   <保存先フォルダ>/<練習の日付>/<HHmm>_<名前>_<航行|監視>_<記録ID>.zip
 *
 * 同じ記録をもう一度受け取ったら(評価・ひとことを書いた後の送り直し)、
 * 古いファイルをゴミ箱へ移して置き換える。
 *
 * 送れるのはチームのメンバーだけ。アプリが添える Firebase の ID トークンで
 * Firestore の users/{uid} と teams/{teamId}/members/{uid} を読み、読めたときだけ保存する。
 * トークンが本物かどうかは Firestore が確かめる(偽のトークンでは読めない)。
 *
 * スクリプト プロパティ(すべて任意):
 *   ROOT_FOLDER_ID    保存先フォルダのID。無ければ「rowing_navigator_logs」を作って記録する
 *   ALLOWED_TEAM_IDS  受け付けるチームIDをカンマ区切りで。空なら、どのチームのメンバーでも受け付ける
 *   FIREBASE_PROJECT_ID  既定は rowing-navigator-tsukuba
 *
 * 手順: docs/実装計画_2026-11-10_ログの自動回収.md の「受け口の用意」
 */

var DEFAULT_PROJECT_ID = 'rowing-navigator-tsukuba';
var DEFAULT_ROOT_FOLDER_NAME = 'rowing_navigator_logs';
// 1練習のZIPは実測 0.1〜1.2MB。Apps Script の Blob の上限(50MB)より十分小さく区切る。
var MAX_ZIP_BYTES = 30 * 1024 * 1024;

function doGet() {
  return json_({ ok: true, service: 'rowing-navigator-log-upload', version: 1 });
}

function doPost(e) {
  try {
    var body = JSON.parse((e && e.postData && e.postData.contents) || '{}');
    var request = validateRequest_(body);
    var member = verifyMember_(body.idToken, body.appCheckToken);
    var allowed = allowedTeamIds_();
    if (allowed.length > 0 && allowed.indexOf(member.teamId) < 0) {
      console.warn('team_not_allowed teamId=' + member.teamId + ' uid=' + member.uid);
      return json_({ ok: false, error: 'team_not_allowed' });
    }
    var saved = saveZip_(request, member);
    console.log('saved ' + saved.path + ' uid=' + member.uid + ' teamId=' + member.teamId);
    return json_({ ok: true, path: saved.path, replaced: saved.replaced });
  } catch (error) {
    var code = error && error.code ? error.code : 'server_error';
    console.warn(code + ': ' + (error && error.message ? error.message : error));
    return json_({ ok: false, error: code });
  }
}

function validateRequest_(body) {
  if (body.v !== 1) throw fail_('bad_request', 'unsupported version');
  if (typeof body.idToken !== 'string' || body.idToken.length < 20) {
    throw fail_('unauthorized', 'missing idToken');
  }
  if (body.kind !== 'session' && body.kind !== 'practiceLog') {
    throw fail_('bad_request', 'kind');
  }
  // 練習記録は数字のID、監視ログは practice_YYYYMMDD_HHMM(SS)。
  var idPattern = body.kind === 'session' ? /^[0-9A-Za-z_-]{1,64}$/ : /^practice_[0-9]{8}_[0-9]{4,6}$/;
  if (typeof body.recordId !== 'string' || !idPattern.test(body.recordId)) {
    throw fail_('bad_request', 'recordId');
  }
  var startedAt = new Date(body.startedAt);
  if (isNaN(startedAt.getTime())) throw fail_('bad_request', 'startedAt');
  if (typeof body.zipBase64 !== 'string' || body.zipBase64.length === 0) {
    throw fail_('bad_request', 'zip');
  }
  var bytes = Utilities.base64Decode(body.zipBase64);
  if (bytes.length > MAX_ZIP_BYTES) throw fail_('too_large', bytes.length + ' bytes');
  // ZIPの先頭は "PK"。
  if (bytes.length < 4 || bytes[0] !== 0x50 || bytes[1] !== 0x4b) {
    throw fail_('bad_request', 'not a zip');
  }
  return {
    kind: body.kind,
    recordId: body.recordId,
    startedAt: startedAt,
    displayName: safeName_(body.displayName),
    bytes: bytes,
  };
}

/** ID トークンでチームのメンバーかを確かめ、{uid, teamId} を返す。 */
function verifyMember_(idToken, appCheckToken) {
  var projectId = prop_('FIREBASE_PROJECT_ID') || DEFAULT_PROJECT_ID;
  var claims = decodeJwtPayload_(idToken);
  // 中身の事前確認。本物かどうかは、下の Firestore の読み取りで確かめる。
  if (claims.aud !== projectId || claims.iss !== 'https://securetoken.google.com/' + projectId) {
    throw fail_('unauthorized', 'wrong project');
  }
  if (!claims.exp || claims.exp * 1000 < Date.now()) throw fail_('unauthorized', 'expired');
  var uid = claims.user_id || claims.sub;
  if (typeof uid !== 'string' || !/^[A-Za-z0-9]{1,128}$/.test(uid)) {
    throw fail_('unauthorized', 'uid');
  }

  var user = firestoreGet_(projectId, 'users/' + uid, idToken, appCheckToken);
  var teamId = user && user.fields && user.fields.teamId && user.fields.teamId.stringValue;
  if (!teamId || !/^[A-Za-z0-9_-]{1,128}$/.test(teamId)) throw fail_('not_member', 'no team');
  var membership = firestoreGet_(projectId, 'teams/' + teamId + '/members/' + uid, idToken, appCheckToken);
  if (!membership) throw fail_('not_member', 'no membership');
  return { uid: uid, teamId: teamId };
}

function firestoreGet_(projectId, path, idToken, appCheckToken) {
  var url = 'https://firestore.googleapis.com/v1/projects/' + projectId +
      '/databases/(default)/documents/' + path;
  var headers = { Authorization: 'Bearer ' + idToken };
  if (typeof appCheckToken === 'string' && appCheckToken.length > 0) {
    headers['X-Firebase-AppCheck'] = appCheckToken;
  }
  var response = UrlFetchApp.fetch(url, { method: 'get', headers: headers, muteHttpExceptions: true });
  var status = response.getResponseCode();
  if (status === 200) return JSON.parse(response.getContentText());
  if (status === 404) return null;
  if (status === 401) throw fail_('unauthorized', 'firestore 401');
  if (status === 403) throw fail_('not_member', 'firestore 403 ' + path.split('/')[0]);
  throw fail_('firestore_unavailable', 'firestore ' + status);
}

function saveZip_(request, member) {
  var lock = LockService.getScriptLock();
  lock.waitLock(30000);
  try {
    var root = rootFolder_();
    var day = Utilities.formatDate(request.startedAt, 'Asia/Tokyo', 'yyyy-MM-dd');
    var folder = childFolder_(root, day);
    var time = Utilities.formatDate(request.startedAt, 'Asia/Tokyo', 'HHmm');
    var label = request.kind === 'session' ? '航行' : '監視';
    var name = [time, request.displayName || member.uid.substring(0, 6), label, request.recordId]
        .join('_') + '.zip';

    var old = [];
    var existing = folder.searchFiles('title contains "' + request.recordId + '" and trashed = false');
    while (existing.hasNext()) old.push(existing.next());

    var blob = Utilities.newBlob(request.bytes, 'application/zip', name);
    var file = folder.createFile(blob);
    file.setDescription('uid=' + member.uid + ' teamId=' + member.teamId +
        ' kind=' + request.kind + ' recordId=' + request.recordId);
    for (var i = 0; i < old.length; i++) old[i].setTrashed(true);
    return { path: day + '/' + name, replaced: old.length };
  } finally {
    lock.releaseLock();
  }
}

function rootFolder_() {
  var props = PropertiesService.getScriptProperties();
  var id = props.getProperty('ROOT_FOLDER_ID');
  if (id) return DriveApp.getFolderById(id);
  var found = DriveApp.getRootFolder().getFoldersByName(DEFAULT_ROOT_FOLDER_NAME);
  var folder = found.hasNext() ? found.next() : DriveApp.getRootFolder().createFolder(DEFAULT_ROOT_FOLDER_NAME);
  props.setProperty('ROOT_FOLDER_ID', folder.getId());
  return folder;
}

function childFolder_(parent, name) {
  var found = parent.getFoldersByName(name);
  return found.hasNext() ? found.next() : parent.createFolder(name);
}

function allowedTeamIds_() {
  var raw = prop_('ALLOWED_TEAM_IDS') || '';
  return raw.split(',').map(function (s) { return s.trim(); }).filter(function (s) { return s; });
}

function prop_(key) {
  return PropertiesService.getScriptProperties().getProperty(key);
}

function decodeJwtPayload_(token) {
  var parts = token.split('.');
  if (parts.length !== 3) throw fail_('unauthorized', 'malformed token');
  var segment = parts[1].replace(/-/g, '+').replace(/_/g, '/');
  while (segment.length % 4 !== 0) segment += '=';
  try {
    return JSON.parse(Utilities.newBlob(Utilities.base64Decode(segment)).getDataAsString());
  } catch (error) {
    throw fail_('unauthorized', 'malformed token');
  }
}

/** ファイル名に使えない文字を除いた名前(20文字まで)。無ければ空文字。 */
function safeName_(name) {
  if (typeof name !== 'string') return '';
  return name.replace(/[\u0000-\u001f\u007f\/\\:*?"<>|_]/g, '').trim().substring(0, 20);
}

function fail_(code, message) {
  var error = new Error(message);
  error.code = code;
  return error;
}

function json_(value) {
  return ContentService.createTextOutput(JSON.stringify(value))
      .setMimeType(ContentService.MimeType.JSON);
}

/**
 * エディタから一度だけ実行し、ドライブと外部通信の許可を出すための関数。
 * 保存先フォルダもここで作られる。
 */
function setup() {
  var folder = rootFolder_();
  console.log('保存先: ' + folder.getName() + ' (' + folder.getUrl() + ')');
  UrlFetchApp.fetch('https://firestore.googleapis.com/', { muteHttpExceptions: true });
}
