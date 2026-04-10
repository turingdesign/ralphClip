# Skills Library

Reusable prompt skill files for RalphClip agents. Reference a skill in your agent TOML with:

```toml
skill = "marketing/article-writing"     # → skills/marketing/article-writing.md
skill = "vue/vue-spa"                   # → skills/vue/vue-spa.md
skill = "general/review-code"           # → skills/general/review-code.md
```

The orchestrator loads `skills/<skill>.md` and prepends it to the agent's prompt.

## Marketing

| Skill | File | Best For |
|-------|------|----------|
| Market Research | `marketing/market-research` | Personas, competitor audits, keyword research, VOC |
| Content Strategy | `marketing/content-strategy` | Content pillars, editorial calendars, campaign briefs |
| Brand Voice | `marketing/brand-voice` | Voice guides, messaging frameworks, tone matrices |
| Article Writing | `marketing/article-writing` | Blog posts, thought leadership, how-to guides, pillar content |
| SEO Strategy | `marketing/seo-strategy` | On-page audits, content clusters, keyword mapping |
| Conversion Copy | `marketing/conversion-copy` | Landing pages, sales pages, pricing pages, A/B variants |
| Email Marketing | `marketing/email-marketing` | Welcome sequences, nurture drips, launch sequences |
| Social Media | `marketing/social-media-strategy` | Platform strategy, content calendars, post creation |

## WordPress / Bricks Builder

| Skill | File | Best For |
|-------|------|----------|
| Bricks Page Design | `wordpress/bricks-page-design` | Landing pages, templates, headers/footers, sections |
| Bricks UI/UX | `wordpress/bricks-ui-ux` | Design systems, layout design, accessibility, mobile-first |
| Bricks Element Dev | `wordpress/bricks-element-dev` | Custom Bricks elements (PHP), controls, rendering |
| WP Plugin Dev | `wordpress/wp-plugin-dev` | Plugin architecture, REST API, settings, security |
| WP Site Architecture | `wordpress/wp-site-architecture` | CPTs, taxonomies, roles, navigation, data models |
| WP Performance | `wordpress/wp-performance` | Core Web Vitals, caching, image optimisation, database |
| WooCommerce | `wordpress/wp-woocommerce` | Products, checkout, payment gateways, shipping, orders |

## Vue.js / PWA

| Skill | File | Best For |
|-------|------|----------|
| Vue SPA | `vue/vue-spa` | Single-page applications, Composition API, Vite |
| Vue PWA | `vue/vue-pwa` | Offline-first, service workers, installable apps |
| Vue Components | `vue/vue-component` | Reusable UI components, accessibility, design systems |
| Vue Data Viz | `vue/vue-data-viz` | Charts, dashboards, Chart.js, D3, sql.js |
| Nuxt App | `vue/nuxt-app` | SSR/SSG, server routes, SEO, full-stack Vue |

## General

| Skill | File | Best For |
|-------|------|----------|
| Decompose | `general/decompose` | CTO epic → story breakdown, dependency ordering |
| Code Review | `general/review-code` | Security, correctness, performance, maintainability |
| Write Tests | `general/write-tests` | Unit tests, integration tests, frontend tests |
| Tech Docs | `general/tech-docs` | READMEs, API docs, architecture docs, changelogs |
| API Design | `general/api-design` | REST API design, validation, auth, pagination |
| Data Modelling | `general/data-modelling` | Schema design, migrations, query optimisation |

## Writing Your Own

A skill file is a Markdown file containing:
1. A role statement ("You are a...")
2. Context-reading instructions (what files to read before starting)
3. Task descriptions (what this skill is used for)
4. Rules (coding standards, quality bars, output format)
5. The completion marker instruction (`<promise>COMPLETE</promise>`)

See [Creating Agents](docs/CREATING-AGENTS.md) for how skills connect to agents.
