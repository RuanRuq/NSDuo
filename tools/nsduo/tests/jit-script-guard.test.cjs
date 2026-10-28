const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');

const root = path.resolve(__dirname, '../../..');
const swift = fs.readFileSync(path.join(root, 'src/MeloNX/MeloNX/Common/JIT/EnableJIT.swift'), 'utf8');
const wrapper = swift.split('let guardedSource = """')[1].split('"""')[0];
assert.ok(wrapper.includes('\\(source)'));

for (const reply of ['OK', '', 'E14', null, undefined]) {
    const commands = [];
    let ready = false;
    const context = {
        prepare_memory_region: () => reply,
        send_command: command => { commands.push(command); return 'OK'; },
        markReady: () => { ready = true; }
    };
    const source = wrapper.replace('\\(source)',
        'prepare_memory_region(0x7020000000n, 16384n); send_command("D"); markReady();');
    let error;
    try { vm.runInNewContext(source, context); } catch (e) { error = e; }
    if (reply === 'OK') {
        assert.equal(error, undefined);
        assert.equal(ready, true);
    } else {
        assert.ok(error, `must fail for ${reply}`);
        assert.equal(ready, false);
    }
    assert.deepEqual(commands, ['D'], 'detach once after success or error');
}
console.log('PASS: actual embedded script stops on failed memory preparation; success and detach paths verified');
