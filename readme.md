a poorly-written `iedit` impl

https://github.com/haolian9/zongzi/assets/6236829/e0bb9e13-359c-4229-a694-936ec3e30b96


## design choices, features, limits
* interactive
  * [x] input the pattern
  * [x] select a region, when treesitter is available
  * [x] select a line range when treesitter is inavailable
  * [ ] opt-in/out on each occurrence, i think that's too cumbersome
* one and only one active session for each buffer
* only one truth of source, all others are replicas
* no realtime syncing, must have a delay time
* syncing changes to the buffer directly rather than changing extmarks
  * i found it's hard to maintance the integrity between buffer content and extmark, during
    user editing, especially undo/redo .
* vim-flavored pattern
* compatible with **utf-8** characters
* [ ] record ops using vim.on_key and replay the ops to all replicas

## status
* WIP: i'm not happy with its current impl.

## prerequisites
* nvim 0.10.*
* haolian9/infra.nvim
* haolian9/puff.nvim
* haolian9/squirrel.nvim

## usage
here's my personal config
```
do --ido
  m.x("gi", ":lua require'ido'.activate_interactively()<cr>")
  m.x("ga", ":lua require'ido'.activate()<cr>")

  do --:Ido
    local spell = cmds.Spell("Ido", function(args, ctx)
      local op = (function()
        if args.op ~= nil then return args.op end
        if ctx.range == 0 then return "deactivate" end
        return "activate"
      end)()
      assert(require("ido")[op])()
    end)
    spell:add_arg("op", "string", false, nil, cmds.ArgComp.constant({ "activate", "activate_interactively", "deactivate" }))
    spell:enable("range")
    cmds.cast(spell)
  end
end
```

## credits
* i learnt about this `iedit` from [iedit.nvim](https://github.com/altermo/iedit.nvim), yet still rolled my own
* https://www.masteringemacs.org/article/iedit-interactive-multi-occurrence-editing-in-your-buffer

## about the name

![ido](https://github.com/haolian9/zongzi/assets/6236829/823975ca-9300-4f50-9d2c-94a048e1539e)
