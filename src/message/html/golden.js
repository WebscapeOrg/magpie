// Capture the maintained JS corpus to compare both production renderers.
// Historical benchmark fixtures remain immutable and are measured separately.
const loader = require(process.cwd() + '/ui/tests/load.js');
const original = loader.load;
const cases = [];
loader.load = function(path) {
  const module = original(path);
  if (path === 'message/Html.js') {
    const sanitize = module.sanitize;
    module.sanitize = function(source, options) {
      const comparable = Object.assign({}, options || {});
      const result = sanitize(source, comparable);
      const expected = Object.assign({},result); delete expected.document; if (expected.plainText) expected.plainText = Object.assign({},expected.plainText,{bodyDirection:module.Direction.resolveBody(expected.plainText.text,"Auto")}); if (expected.reader) { expected.reader = Object.assign({},expected.reader); delete expected.reader.document; } cases.push({source, options: comparable, expected});
      return result;
    };
  }
  return module;
};
const write = process.stdout.write;
process.stdout.write = () => true;
require(process.cwd() + '/ui/tests/test_html.js');
process.stdout.write = write;
process.stdout.write(JSON.stringify(cases));
