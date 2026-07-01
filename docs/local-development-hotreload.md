# Local development with hot reload

This sets up a version of the app on your computer that **updates as you edit the
code** — no rebuilding the whole image every time. It runs alongside your normal
setup and does not affect how the app is deployed to a real server.

## What "hot reload" means here

- **Ruby changes** (controllers, models, the `lib` logic, page templates): take
  effect on the next page load. Just refresh the browser.
- **JavaScript / Vue / styling changes** (e.g. the template builder screens):
  recompile automatically. Refresh the browser to see them (the first refresh
  after a change takes a few seconds while it rebuilds).

You do **not** need to rebuild or restart anything for normal code edits.

## Start it

```
docker compose -f docker-compose.dev.yml up
```

The first time, this builds the development image (downloads fonts and the PDF
tools, installs everything). That takes several minutes. After that, starting is
quick.

Then open: **http://localhost:3015**

## Stop it

Press `Ctrl+C` in the terminal, or run:

```
docker compose -f docker-compose.dev.yml down
```

## Good to know

- **Separate from your other setup.** This dev app uses its own database, so it
  has its **own login/account** and won't touch the data in your existing local
  container (which runs on port 3010). The first time you open it, create a new
  account.
- **Production is untouched.** Deploys still use the regular `Dockerfile`. These
  two new files (`Dockerfile.dev` and `docker-compose.dev.yml`) are for local
  development only.
- **Background jobs and email work too.** Things like PDF generation and email
  reminders run inside the same container. Emails are not actually sent in dev —
  you can view them at **http://localhost:3015/letter_opener**.
- **When you add a new gem or JS package** (edit `Gemfile` or `package.json`),
  rebuild once:
  ```
  docker compose -f docker-compose.dev.yml up --build
  ```
- **Database changes (migrations)** are applied automatically each time you start
  the dev stack. To apply one without restarting:
  ```
  docker compose -f docker-compose.dev.yml exec app bundle exec rails db:migrate
  ```
- **Reset the dev database** (start fresh): stop the stack, then:
  ```
  docker compose -f docker-compose.dev.yml down -v
  ```
  (The `-v` also clears the dev uploads.)
