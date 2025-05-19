"use strict";
var __awaiter = (this && this.__awaiter) || function (thisArg, _arguments, P, generator) {
    function adopt(value) { return value instanceof P ? value : new P(function (resolve) { resolve(value); }); }
    return new (P || (P = Promise))(function (resolve, reject) {
        function fulfilled(value) { try { step(generator.next(value)); } catch (e) { reject(e); } }
        function rejected(value) { try { step(generator["throw"](value)); } catch (e) { reject(e); } }
        function step(result) { result.done ? resolve(result.value) : adopt(result.value).then(fulfilled, rejected); }
        step((generator = generator.apply(thisArg, _arguments || [])).next());
    });
};
var __generator = (this && this.__generator) || function (thisArg, body) {
    var _ = { label: 0, sent: function() { if (t[0] & 1) throw t[1]; return t[1]; }, trys: [], ops: [] }, f, y, t, g;
    return g = { next: verb(0), "throw": verb(1), "return": verb(2) }, typeof Symbol === "function" && (g[Symbol.iterator] = function() { return this; }), g;
    function verb(n) { return function (v) { return step([n, v]); }; }
    function step(op) {
        if (f) throw new TypeError("Generator is already executing.");
        while (g && (g = 0, op[0] && (_ = 0)), _) try {
            if (f = 1, y && (t = op[0] & 2 ? y["return"] : op[0] ? y["throw"] || ((t = y["return"]) && t.call(y), 0) : y.next) && !(t = t.call(y, op[1])).done) return t;
            if (y = 0, t) op = [op[0] & 2, t.value];
            switch (op[0]) {
                case 0: case 1: t = op; break;
                case 4: _.label++; return { value: op[1], done: false };
                case 5: _.label++; y = op[1]; op = [0]; continue;
                case 7: op = _.ops.pop(); _.trys.pop(); continue;
                default:
                    if (!(t = _.trys, t = t.length > 0 && t[t.length - 1]) && (op[0] === 6 || op[0] === 2)) { _ = 0; continue; }
                    if (op[0] === 3 && (!t || (op[1] > t[0] && op[1] < t[3]))) { _.label = op[1]; break; }
                    if (op[0] === 6 && _.label < t[1]) { _.label = t[1]; t = op; break; }
                    if (t && _.label < t[2]) { _.label = t[2]; _.ops.push(op); break; }
                    if (t[2]) _.ops.pop();
                    _.trys.pop(); continue;
            }
            op = body.call(thisArg, _);
        } catch (e) { op = [6, e]; y = 0; } finally { f = t = 0; }
        if (op[0] & 5) throw op[1]; return { value: op[0] ? op[1] : void 0, done: true };
    }
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.md5 = exports.verifyUrl = exports.signUrl = exports.sign = void 0;
function sign(str, key) {
    return __awaiter(this, void 0, void 0, function () {
        var encoder, importedKey, mac, base64Mac;
        return __generator(this, function (_a) {
            switch (_a.label) {
                case 0:
                    encoder = new TextEncoder();
                    return [4 /*yield*/, crypto.subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["verify"])];
                case 1:
                    importedKey = _a.sent();
                    return [4 /*yield*/, crypto.subtle.sign("HMAC", importedKey, encoder.encode(str))];
                case 2:
                    mac = _a.sent();
                    base64Mac = btoa(String.fromCharCode.apply(String, new Uint8Array(mac)));
                    // must convert "+" to "-" as urls encode "+" as " "
                    base64Mac = base64Mac.replaceAll("+", "-");
                    return [2 /*return*/, base64Mac];
            }
        });
    });
}
exports.sign = sign;
function signUrl(url, key) {
    return __awaiter(this, void 0, void 0, function () {
        var code, newUrl;
        return __generator(this, function (_a) {
            switch (_a.label) {
                case 0: return [4 /*yield*/, sign(url.toString(), key)];
                case 1:
                    code = _a.sent();
                    newUrl = new URL(url);
                    newUrl.searchParams.append("code", code);
                    return [2 /*return*/, newUrl];
            }
        });
    });
}
exports.signUrl = signUrl;
function verifyUrl(url, key) {
    return __awaiter(this, void 0, void 0, function () {
        var code, urlWithoutCode, expectedCode;
        return __generator(this, function (_a) {
            switch (_a.label) {
                case 0:
                    code = url.searchParams.get("code");
                    urlWithoutCode = new URL(url);
                    urlWithoutCode.searchParams.delete("code");
                    return [4 /*yield*/, sign(urlWithoutCode.toString(), key)];
                case 1:
                    expectedCode = _a.sent();
                    return [2 /*return*/, code === expectedCode];
            }
        });
    });
}
exports.verifyUrl = verifyUrl;
function md5(str) {
    return __awaiter(this, void 0, void 0, function () {
        var encoder, hash, decoder;
        return __generator(this, function (_a) {
            switch (_a.label) {
                case 0:
                    encoder = new TextEncoder();
                    return [4 /*yield*/, crypto.subtle.digest("MD5", encoder.encode(str))];
                case 1:
                    hash = _a.sent();
                    decoder = new TextDecoder();
                    return [2 /*return*/, decoder.decode(hash)];
            }
        });
    });
}
exports.md5 = md5;
