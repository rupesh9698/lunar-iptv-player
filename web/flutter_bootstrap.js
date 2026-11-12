{{flutter_js}}
{{flutter_build_config}}

// Give the app script a new address on every build, so browsers always
// load the latest deploy. (An earlier hosting setting let browsers keep
// main.dart.js for a week, and a normal reload kept using that copy.)
(function () {
  var v = {{flutter_service_worker_version}};
  (_flutter.buildConfig.builds || []).forEach(function (b) {
    if (b.mainJsPath && b.mainJsPath.indexOf('?') < 0) {
      b.mainJsPath += '?v=' + v;
    }
  });
})();

_flutter.loader.load();
