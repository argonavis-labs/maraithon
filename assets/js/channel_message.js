// Render Slack's common message formatting without interpreting arbitrary HTML.
// The draft text sent to Slack stays unchanged.
export function renderSlackMessage(target, text) {
  const fragment = document.createDocumentFragment()
  const tokens = /```([\s\S]+?)```|`([^`\n]+)`|<(https?:\/\/[^>|\s]+)(?:\|([^>]+))?>|\*([^*\n]+)\*|_([^_\n]+)_|~([^~\n]+)~/g
  const decode = value => value.replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
  let offset = 0
  for (const match of text.matchAll(tokens)) {
    fragment.append(document.createTextNode(decode(text.slice(offset, match.index))))
    let node
    if (match[3]) {
      node = document.createElement('a')
      node.href = decode(match[3])
      node.target = '_blank'
      node.rel = 'noopener noreferrer'
      node.className = 'underline'
      node.textContent = decode(match[4] || match[3])
    } else {
      const tag = match[1] ? 'pre' : match[2] ? 'code' : match[5] ? 'strong' : match[6] ? 'em' : 'del'
      node = document.createElement(tag)
      node.textContent = decode(match[1] || match[2] || match[5] || match[6] || match[7])
    }
    fragment.append(node)
    offset = match.index + match[0].length
  }
  fragment.append(document.createTextNode(decode(text.slice(offset))))
  target.replaceChildren(fragment)
}
