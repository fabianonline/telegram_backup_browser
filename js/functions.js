function makePasswordHash (salt, password, CryptoWorker) {
    var passwordUTF8 = unescape(encodeURIComponent(password));

    var buffer   = new ArrayBuffer(passwordUTF8.length);
    var byteView = new Uint8Array(buffer);
    for (var i = 0, len = passwordUTF8.length; i < len; i++) {
      byteView[i] = passwordUTF8.charCodeAt(i);
    }

    buffer = bufferConcat(bufferConcat(salt, byteView), salt);

    return CryptoWorker.sha256Hash(buffer);
  }
