// ConfigStorage
(function (window) {
  var keyPrefix = '';
  var noPrefix = false;
  var cache = {};
  var useCs = !!(window.chrome && chrome.storage && chrome.storage.local);
  var useLs = !useCs && !!window.localStorage;

  function storageSetPrefix (newPrefix) {
    keyPrefix = newPrefix;
  }

  function storageSetNoPrefix() {
    noPrefix = true;
  }

  function storageGetPrefix () {
    if (noPrefix) {
      noPrefix = false;
      return '';
    }
    return keyPrefix;
  }

  function storageGetValue(keys, callback) {
    var single = false;
    if (!Array.isArray(keys)) {
      keys = Array.prototype.slice.call(arguments);
      callback = keys.pop();
      single = keys.length == 1;
    }
    var result = [],
        value,
        allFound = true,
        prefix = storageGetPrefix(),
        i, key;

    for (i = 0; i < keys.length; i++) {
      key = keys[i] = prefix + keys[i];
      if (key.substr(0, 3) != 'xt_' && cache[key] !== undefined) {
        result.push(cache[key]);
      }
      else if (useLs) {
        try {
          value = localStorage.getItem(key);
        } catch (e) {
          useLs = false;
        }
        try {
          value = (value === undefined || value === null) ? false : JSON.parse(value);
        } catch (e) {
          value = false;
        }
        result.push(cache[key] = value);
      }
      else if (!useCs) {
        result.push(cache[key] = false);
      }
      else {
        allFound = false;
      }
    }

    if (allFound) {
      return callback(single ? result[0] : result);
    }

    chrome.storage.local.get(keys, function (resultObj) {
      var value;
      result = [];
      for (i = 0; i < keys.length; i++) {
        key = keys[i];
        value = resultObj[key];
        value = value === undefined || value === null ? false : JSON.parse(value);
        result.push(cache[key] = value);
      }

      callback(single ? result[0] : result);
    });
  };

  function storageSetValue(obj, callback) {
    var keyValues = {},
        prefix = storageGetPrefix(),
        key, value;

    for (key in obj) {
      if (obj.hasOwnProperty(key)) {
        value = obj[key];
        key = prefix + key;
        cache[key] = value;
        value = JSON.stringify(value);
        if (useLs) {
          try {
            localStorage.setItem(key, value);
          } catch (e) {
            useLs = false;
          }
        } else {
          keyValues[key] = value;
        }
      }
    }

    if (useLs || !useCs) {
      if (callback) {
        callback();
      }
      return;
    }

    chrome.storage.local.set(keyValues, callback);
  };

  function storageRemoveValue (keys, callback) {
    if (!Array.isArray(keys)) {
      keys = Array.prototype.slice.call(arguments);
      if (typeof keys[keys.length - 1] === 'function') {
        callback = keys.pop();
      }
    }
    var prefix = storageGetPrefix(),
        i, key;


    for (i = 0; i < keys.length; i++) {
      key = keys[i] = prefix + keys[i];
      delete cache[key];
      if (useLs) {
        try {
          localStorage.removeItem(key);
        } catch (e) {
          useLs = false;
        }
      }
    }
    if (useCs) {
      chrome.storage.local.remove(keys, callback);
    }
    else if (callback) {
      callback();
    }
  };

  function storageClear(callback) {
    if (useLs) {
      try {
        localStorage.clear();
      } catch (e) {
        useLs = false;
      }
    }

    if (useCs) {
      chrome.storage.local.clear(function () {
        cache = {};
        callback();
      });
    } else {
      cache = {};
      callback();
    }
  };

  window.ConfigStorage = {
    prefix: storageSetPrefix,
    noPrefix: storageSetNoPrefix,
    get: storageGetValue,
    set: storageSetValue,
    remove: storageRemoveValue,
    clear: storageClear
  };

})(this);
