import type { Register } from 'claude-code'

// A band above the prompt with one Button, the shape whose keyboard focus
// tests/fm-claude-band-focus-live-e2e.test.sh proves firstmate releases.
export const register: Register = on => {
  on('ui.render', { component: 'AbovePrompt' }, ($, e, next) => {
    const { Box, Button, Text } = $.ui.resolve(e)
    return (
      <Box flexDirection="column">
        <Text dimColor>fm band fixture</Text>
        <Button key="noop" label="Noop" onPress={() => undefined} />
      </Box>
    )
  })
}
