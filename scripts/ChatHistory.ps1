. (Join-Path $PSScriptRoot 'MigrationCommon.ps1')

if (-not ('LmtChatSnapshot' -as [type])) {
    Add-Type -ReferencedAssemblies System.Web.Extensions -TypeDefinition @'
using System;
using System.IO;
using System.Collections;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Text;
using System.Web.Script.Serialization;

public sealed class LmtChatSnapshot {
    public string SessionId;
    public string Title;
    public double Created;
    public double Activity;
    public string[] RequestIds;
    public string[] Messages;
    public string ContentHash;
    public int Count { get { return RequestIds.Length; } }

    static JavaScriptSerializer Json() {
        return new JavaScriptSerializer { MaxJsonLength = int.MaxValue, RecursionLimit = 1024 };
    }
    static string Hash(string value) {
        using (var sha = SHA256.Create())
            return Convert.ToBase64String(sha.ComputeHash(Encoding.UTF8.GetBytes(value)));
    }
    static object At(object obj, object key) {
        var dict = obj as IDictionary<string, object>;
        if (dict != null) return dict[(string)key];
        return ((IList)obj)[Convert.ToInt32(key)];
    }
    static void Set(object obj, object key, object value) {
        var dict = obj as IDictionary<string, object>;
        if (dict != null) dict[(string)key] = value;
        else ((IList)obj)[Convert.ToInt32(key)] = value;
    }
    static double Number(IDictionary<string, object> obj, string key) {
        object value;
        return obj.TryGetValue(key, out value) && value != null ? Convert.ToDouble(value) : 0;
    }
    public static LmtChatSnapshot Read(string path) {
        var json = Json();
        IDictionary<string, object> state = null;
        using (var file = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
        using (var reader = new StreamReader(file)) {
            if (Path.GetExtension(path).Equals(".json", StringComparison.OrdinalIgnoreCase)) {
                state = (IDictionary<string, object>)json.DeserializeObject(reader.ReadToEnd());
            } else {
                string line;
                while ((line = reader.ReadLine()) != null) {
                    if (String.IsNullOrWhiteSpace(line)) continue;
                    var record = (IDictionary<string, object>)json.DeserializeObject(line);
                    int kind = Convert.ToInt32(record["kind"]);
                    if (kind == 0) {
                        state = (IDictionary<string, object>)record["v"];
                        continue;
                    }
                    if (state == null) throw new InvalidDataException("Chat journal has no initial snapshot: " + path);
                    var keys = (IList)record["k"];
                    if (keys.Count == 0) throw new InvalidDataException("Empty journal key: " + path);
                    object parent = state;
                    for (int i = 0; i < keys.Count - 1; i++) parent = At(parent, keys[i]);
                    object key = keys[keys.Count - 1];
                    if (kind == 1) Set(parent, key, record["v"]);
                    else if (kind == 3) {
                        var dict = parent as IDictionary<string, object>;
                        if (dict != null) dict.Remove((string)key);
                        else Set(parent, key, null);
                    }
                    else if (kind == 2) {
                        var dict = parent as IDictionary<string, object>;
                        object old;
                        if (dict != null) dict.TryGetValue((string)key, out old);
                        else old = At(parent, key);
                        var combined = old == null ? new ArrayList() : new ArrayList((ICollection)old);
                        if (record.ContainsKey("i")) {
                            int length = Convert.ToInt32(record["i"]);
                            if (length < 0 || length > combined.Count) throw new InvalidDataException("Invalid array truncation: " + path);
                            combined.RemoveRange(length, combined.Count - length);
                        }
                        if (record.ContainsKey("v") && record["v"] != null) combined.AddRange((ICollection)record["v"]);
                        Set(parent, key, combined);
                    } else throw new InvalidDataException("Unsupported journal operation " + kind + ": " + path);
                }
            }
        }
        if (state == null) throw new InvalidDataException("Empty chat: " + path);
        var requests = (IList)state["requests"];
        var result = new LmtChatSnapshot {
            SessionId = (string)state["sessionId"],
            Title = state.ContainsKey("customTitle") ? state["customTitle"] as string : null,
            Created = Number(state, "creationDate"),
            RequestIds = new string[requests.Count],
            Messages = new string[requests.Count],
            ContentHash = Hash(json.Serialize(requests))
        };
        var unique = new HashSet<string>();
        for (int i = 0; i < requests.Count; i++) {
            var request = (IDictionary<string, object>)requests[i];
            string id = request["requestId"] as string;
            if (String.IsNullOrEmpty(id) || !unique.Add(id))
                throw new InvalidDataException("Missing or duplicate request ID: " + path);
            result.RequestIds[i] = id;
            result.Messages[i] = Hash(json.Serialize(request["message"]));
            result.Activity = Math.Max(result.Activity, Math.Max(Number(request, "timestamp"), Number(request, "responseTimestamp")));
        }
        return result;
    }
    // A longer conversation is safe only when the shorter one is its ordered prompt prefix.
    public static string Compare(LmtChatSnapshot source, LmtChatSnapshot target) {
        if (target == null) return "Newer";
        if (source.SessionId != target.SessionId) return "Conflict";
        for (int i = 0; i < Math.Min(source.Count, target.Count); i++)
            if (source.RequestIds[i] != target.RequestIds[i] || source.Messages[i] != target.Messages[i])
                return "Conflict";
        if (source.Count > target.Count) return target.Activity > source.Activity ? "Conflict" : "Newer";
        if (source.Count < target.Count) return source.Activity > target.Activity ? "Conflict" : "Older";
        if (source.ContentHash == target.ContentHash) return "Same";
        if (source.Activity > target.Activity) return "Newer";
        if (source.Activity < target.Activity) return "Older";
        return "Conflict";
    }
}
'@
}

function Get-ChatSnapshot([string]$Path) { [LmtChatSnapshot]::Read($Path) }

function Copy-ChatTree([string]$Source, [string]$Destination) {
    if (-not (Test-Path -LiteralPath $Source)) { return }
    robocopy $Source $Destination /E /XJ /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Chat copy failed (robocopy rc=$LASTEXITCODE): $Source" }
    foreach ($file in Get-ChildItem -LiteralPath $Source -Recurse -File -Force) {
        $relative = $file.FullName.Substring($Source.TrimEnd('\').Length).TrimStart('\')
        $copy = Join-Path $Destination $relative
        $sourceHash = (Get-FileHash -LiteralPath $file.FullName).Hash
        # Robocopy can skip equal-size/equal-date files whose bytes differ.
        if (-not (Test-Path -LiteralPath $copy) -or $sourceHash -ne (Get-FileHash -LiteralPath $copy).Hash) {
            Copy-Shared $file.FullName $copy
        }
        if ($sourceHash -ne (Get-FileHash -LiteralPath $copy).Hash) {
            throw "Copied chat data hash mismatch: $copy"
        }
    }
}
