#!/usr/bin/env python3
"""Turn a name of a file into a link to that file.

A document that says `bench/gcbench.sh` names a file the reader cannot open.
This rewrites every such mention into a Markdown link with a path relative to
the document, and it does so only when the file exists, so a link can never
point at nothing.

    linkify.py <root> <file.md>...

Rules: a mention is a backticked string that holds a slash or ends in a
known extension; it is skipped inside a fenced code block, when it is
already the text of a link, and when the path does not resolve either beside
the document or at the root of the repository.
"""
import os, re, sys

EXT = (".md", ".jl", ".c", ".h", ".cpp", ".py", ".sh", ".tsv", ".svg", ".toml", ".mk")
PATH = re.compile(r"(?<!\[)`([A-Za-z0-9_][A-Za-z0-9_./-]*)`(?!\]\()")

def main(argv):
    root = os.path.abspath(argv[1])
    for doc in argv[2:]:
        d = os.path.dirname(os.path.abspath(doc))
        out, fenced, n = [], False, 0
        for line in open(doc):
            if line.lstrip().startswith("```"):
                fenced = not fenced
            if fenced or line.startswith("    "):
                out.append(line); continue
            def sub(m):
                nonlocal n
                name = m.group(1)
                if "/" not in name and not name.endswith(EXT):
                    return m.group(0)
                for base in (d, root):
                    target = os.path.join(base, name)
                    if os.path.exists(target):
                        rel = os.path.relpath(target, d)
                        n += 1
                        return f"[`{name}`]({rel})"
                return m.group(0)
            out.append(PATH.sub(sub, line))
        open(doc, "w").writelines(rewrap(out))
        print(f"{doc}: {n} links")


def rewrap(lines, width=78):
    """Wrap a plain paragraph that a link made too long. A table, a list, a
    heading, a quote and a code block keep their lines."""
    out, para, fenced = [], [], False
    def flush():
        if not para:
            return
        text = " ".join(l.strip() for l in para)
        if len(max(para, key=len)) <= width:
            out.extend(para)
        else:
            line = ""
            for word in text.split(" "):
                if line and len(line) + 1 + len(word) > width:
                    out.append(line + "\n"); line = word
                else:
                    line = word if not line else line + " " + word
            if line:
                out.append(line + "\n")
        para.clear()
    for line in lines:
        if line.lstrip().startswith("```"):
            fenced = not fenced
        stripped = line.strip()
        if (fenced or not stripped or line.startswith(("    ", "|", ">", "#", "-", "*"))
                or stripped.startswith(("|", ">", "#", "-", "*", "!["))):
            flush(); out.append(line); continue
        para.append(line)
    flush()
    return out

if __name__ == "__main__":
    sys.exit(main(sys.argv))
