import { useCallback, useEffect, useState } from 'react'
import { ArrowUpRight, Bell, ClipboardList, Image, Loader2, Package, Save, Tags, Truck, Users, Volume2 } from 'lucide-react'
import { Link } from 'react-router-dom'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/lib/auth'
import {
  canUseBrowserNotifications,
  playAdminNotificationSound,
  readAdminPreferences,
  requestBrowserNotificationPermission,
  writeAdminPreferences,
  type AdminPreferences,
} from '@/lib/admin-preferences'

type Setting = { key: string; value: string | null; is_public: boolean }

const GROUPS: { title: string; keys: { key: string; label: string; type: 'text' | 'tel' | 'email' | 'url' | 'textarea'; help?: string }[] }[] = [
  {
    title: 'Contact',
    keys: [
      { key: 'phone', label: 'Téléphone', type: 'tel', help: 'Format algérien, ex. 0550 12 34 56' },
      { key: 'whatsapp', label: 'WhatsApp', type: 'tel' },
      { key: 'email', label: 'Email professionnel', type: 'email' },
      { key: 'address', label: 'Adresse du studio', type: 'text' },
    ],
  },
  {
    title: 'Réseaux sociaux',
    keys: [
      { key: 'instagram_url', label: 'Instagram (URL complète)', type: 'url' },
      { key: 'facebook_url', label: 'Facebook (URL complète)', type: 'url' },
      { key: 'tiktok_url', label: 'TikTok (URL complète)', type: 'url' },
    ],
  },
  {
    title: 'Référencement',
    keys: [
      { key: 'seo_title', label: 'Titre SEO', type: 'text' },
      { key: 'seo_description', label: 'Description SEO', type: 'textarea' },
    ],
  },
  {
    title: 'Politiques et conditions',
    keys: [
      { key: 'policy_returns', label: 'Retours et échanges', type: 'textarea', help: 'Texte validé par vous uniquement.' },
      { key: 'policy_privacy', label: 'Confidentialité', type: 'textarea' },
      { key: 'policy_terms', label: 'Conditions de vente', type: 'textarea' },
    ],
  },
]

export default function AdminSettings() {
  const { profile } = useAuth()
  const [values, setValues] = useState<Record<string, string>>({})
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [saved, setSaved] = useState(false)
  const [preferences, setPreferences] = useState<AdminPreferences>(() => readAdminPreferences(profile?.id ?? null))
  const [preferenceMessage, setPreferenceMessage] = useState<string | null>(null)


  const load = useCallback(async () => {
    setLoading(true)
    const { data: settings, error: queryError } = await supabase.from('store_settings').select('key, value, is_public').order('key')
    if (queryError) {
      setError('Impossible de charger les paramètres du magasin. Aucune valeur n’a été modifiée.')
      setLoading(false)
      return
    }
    const next: Record<string, string> = {}
    ;((settings as Setting[]) ?? []).forEach((row) => {
      next[row.key] = row.value ?? ''
    })
    setValues(next)
    setError(null)
    setLoading(false)
  }, [])

  useEffect(() => {
    load()
  }, [load])

  useEffect(() => {
    setPreferences(readAdminPreferences(profile?.id ?? null))
  }, [profile?.id])

  const updatePreference = <Key extends keyof AdminPreferences,>(key: Key, value: AdminPreferences[Key]) => {
    setPreferences((current) => {
      const next = { ...current, [key]: value }
      if (profile?.id) writeAdminPreferences(profile.id, next)
      return next
    })
  }

  const toggleBrowserNotifications = async () => {
    setPreferenceMessage(null)
    if (preferences.browserNotifications) {
      updatePreference('browserNotifications', false)
      setPreferenceMessage('Les notifications du navigateur sont désactivées.')
      return
    }
    if (!canUseBrowserNotifications()) {
      setPreferenceMessage('Ce navigateur ne prend pas en charge les notifications système.')
      return
    }
    if (window.Notification.permission === 'granted') {
      updatePreference('browserNotifications', true)
      setPreferenceMessage('Les notifications du navigateur sont activées pendant que l’application est ouverte.')
      return
    }
    if (window.Notification.permission === 'denied') {
      setPreferenceMessage('Le navigateur a bloqué les notifications. Autorisez-les dans les paramètres du site, puis réessayez.')
      return
    }
    if (preferences.browserPermissionPrompted) {
      setPreferenceMessage('La demande a déjà été présentée. Modifiez l’autorisation dans les paramètres du navigateur pour l’activer.')
      return
    }
    let permission: NotificationPermission | 'unsupported'
    try {
      permission = await requestBrowserNotificationPermission()
    } catch {
      updatePreference('browserPermissionPrompted', true)
      setPreferenceMessage('Le navigateur n’a pas pu présenter la demande. Vérifiez ses paramètres de site pour activer les notifications.')
      return
    }
    updatePreference('browserPermissionPrompted', true)
    if (permission === 'granted') {
      updatePreference('browserNotifications', true)
      setPreferenceMessage('Les notifications du navigateur sont activées pendant que l’application est ouverte.')
    } else if (permission === 'denied') {
      setPreferenceMessage('Autorisation refusée. Vous pourrez la modifier dans les paramètres du navigateur.')
    } else {
      setPreferenceMessage('Aucune autorisation n’a été accordée. La demande ne sera pas répétée automatiquement.')
    }
  }

  const testSound = () => {
    setPreferenceMessage(
      playAdminNotificationSound()
        ? 'Son de test joué.'
        : 'Le son n’a pas pu être joué par ce navigateur. Vérifiez ses réglages audio.'
    )
  }

  const save = async () => {
    setError(null)
    setSaved(false)

    const invalid = GROUPS.flatMap((group) => group.keys).find((field) => {
      if (field.type !== 'url') return false
      const value = values[field.key]?.trim()
      return value ? !/^https:\/\/[\w.-]+\.[a-z]{2,}\//i.test(value) : false
    })
    if (invalid) {
      setError(`Le lien ${invalid.label} doit être une URL complète en https://`)
      return
    }

    setSaving(true)
    const rows = Object.entries(values).map(([key, value]) => ({
      key,
      value: value.trim() ? value.trim() : null,
    }))
    const { error: writeError } = await supabase
      .from('store_settings')
      .upsert(rows, { onConflict: 'key' })
    setSaving(false)

    if (writeError) {
      setError("Impossible d'enregistrer les paramètres.")
      return
    }
    setSaved(true)
  }


  if (loading) {
    return (
      <div className="flex items-center justify-center py-16">
        <Loader2 className="h-8 w-8 animate-spin text-brand-red" />
      </div>
    )
  }

  return (
    <div className="animate-fade-in">
      <header className="admin-page-header mb-6"><div><p className="admin-eyebrow">Configuration</p><h1 className="text-2xl font-bold text-offwhite">Paramètres du magasin</h1></div></header>
      <p className="mb-6 text-sm text-charcoal-400">
        Ces informations sont publiques et affichées sur la boutique lorsqu'elles sont renseignées.
        Les liens vides sont masqués. Les clés d'API et secrets ne doivent jamais être saisis ici :
        utilisez les secrets de votre hébergeur.
      </p>

      <section className="admin-card mb-6">
        <div className="mb-4">
          <p className="admin-eyebrow">Parcours client</p>
          <h2 className="text-lg font-semibold text-offwhite">Contrôler ce que voit le visiteur</h2>
          <p className="mt-1 text-xs leading-5 text-charcoal-400">Les éléments de la boutique restent reliés aux mêmes données administrées ici : modifiez les contenus à leur source pour les voir reflétés côté client.</p>
        </div>
        <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
          {[
            { to: '/admin/visual-identity', icon: Image, title: 'Accueil et identité visuelle', detail: 'Titres, textes, boutons, images, sections et animations' },
            { to: '/admin/produits', icon: Package, title: 'Produits et fiches', detail: 'Photos, descriptions, prix, options, stock et délais' },
            { to: '/admin/categories', icon: Tags, title: 'Catégories', detail: 'Organisation et navigation du catalogue' },
            { to: '/admin/livraison', icon: Truck, title: 'Livraison', detail: 'Wilayas, tarifs, méthodes et points relais' },
            { to: '/admin/commandes', icon: ClipboardList, title: 'Commandes', detail: 'Commandes reçues et progression de traitement' },
            { to: '/admin/clients', icon: Users, title: 'Clients', detail: 'Comptes, informations et historique client' },
          ].map((item) => {
            const Icon = item.icon
            return (
              <Link key={item.to} to={item.to} className="group flex items-start gap-3 rounded-xl border border-charcoal-400/15 bg-charcoal-900/40 p-4 transition hover:border-brand-red/40 hover:bg-charcoal-900/80">
                <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-lg bg-brand-red/10 text-brand-red-light"><Icon className="h-5 w-5" /></span>
                <span className="min-w-0 flex-1">
                  <strong className="block text-sm text-offwhite">{item.title}</strong>
                  <span className="mt-1 block text-xs leading-5 text-charcoal-400">{item.detail}</span>
                </span>
                <ArrowUpRight className="h-4 w-4 shrink-0 text-charcoal-500 transition group-hover:-translate-y-0.5 group-hover:translate-x-0.5 group-hover:text-brand-red-light" />
              </Link>
            )
          })}
        </div>
      </section>

      <section className="admin-card mb-6">
        <div className="mb-3">
          <p className="admin-eyebrow">Comptes et sécurité</p>
          <h2 className="text-lg font-semibold text-offwhite">Inscription, connexion et récupération</h2>
          <p className="mt-1 text-xs leading-5 text-charcoal-400">
            Les clients gèrent leur compte depuis l’espace personnel. La récupération du mot de passe utilise l’e-mail Supabase Auth; les domaines de retour et le service SMTP doivent être configurés dans Supabase avant l’ouverture publique.
          </p>
        </div>
        <div className="flex flex-wrap gap-2">
          <Link to="/admin/clients" className="btn-secondary">Gérer les clients</Link>
          <Link to="/boutique/compte" className="btn-secondary">Voir l’espace client</Link>
          <a href="https://supabase.com/dashboard" target="_blank" rel="noopener noreferrer" className="btn-secondary">Configuration Supabase</a>
          <a href="https://github.com/lunderclub9-gif/lunder-printe/blob/main/docs/PRELAUNCH_CHECKLIST.md" target="_blank" rel="noopener noreferrer" className="btn-secondary">Checklist avant lancement</a>
        </div>
        <p className="mt-3 text-[11px] leading-5 text-amber-200/80">
          Important : ne renseignez jamais de clé service_role dans les paramètres de la boutique ou dans une variable VITE_*. Vérifiez le projet Supabase et les URL de redirection avant d’activer les inscriptions publiques.
        </p>
      </section>

      {error && (
        <div role="alert" className="admin-feedback admin-feedback-error mb-4">
          {error}
        </div>
      )}
      {saved && (
        <div role="status" className="admin-feedback admin-feedback-success mb-4">
          Paramètres enregistrés.
        </div>
      )}

      <div className="space-y-6">
        {GROUPS.map((group) => (
          <section key={group.title} className="admin-card">
            <h2 className="mb-4 text-lg font-semibold text-offwhite">{group.title}</h2>
            <div className="grid gap-4 sm:grid-cols-2">
              {group.keys.map((field) => (
                <label
                  key={field.key}
                  className={`block ${field.type === 'textarea' ? 'sm:col-span-2' : ''}`}
                >
                  <span className="label-text">{field.label}</span>
                  {field.type === 'textarea' ? (
                    <textarea
                      rows={field.key.startsWith('policy_') ? 5 : 3}
                      value={values[field.key] ?? ''}
                      onChange={(event) =>
                        setValues((current) => ({ ...current, [field.key]: event.target.value }))
                      }
                      className="input-field resize-none"
                    />
                  ) : (
                    <input
                      type={field.type}
                      value={values[field.key] ?? ''}
                      onChange={(event) =>
                        setValues((current) => ({ ...current, [field.key]: event.target.value }))
                      }
                      className="input-field"
                      placeholder={field.help ?? ''}
                    />
                  )}
                  {field.help && <span className="mt-1 block text-xs text-charcoal-500">{field.help}</span>}
                </label>
              ))}
            </div>
          </section>
        ))}

        <section className="admin-card">
          <div className="mb-4 flex items-center gap-2">
            <Bell className="h-5 w-5 text-brand-red-light" />
            <h2 className="text-lg font-semibold text-offwhite">Notifications du propriétaire</h2>
          </div>
          <p className="mb-4 text-xs leading-relaxed text-charcoal-400">
            Les préférences sont conservées sur ce navigateur et cet appareil. Les événements de commande et de demande sont enregistrés côté base de données.
          </p>
          <div className="space-y-4">
            <label className="flex items-center justify-between gap-4 rounded-lg border border-charcoal-400/15 p-3">
              <span>
                <span className="block text-sm font-medium text-offwhite">Notifications internes</span>
                <span className="block text-xs text-charcoal-400">Centre et compteur dans l’en-tête admin</span>
              </span>
              <input type="checkbox" checked={preferences.inAppNotifications} onChange={(event) => updatePreference('inAppNotifications', event.target.checked)} className="h-4 w-4 accent-brand-red" />
            </label>
            <label className="flex items-center justify-between gap-4 rounded-lg border border-charcoal-400/15 p-3">
              <span>
                <span className="block text-sm font-medium text-offwhite">Nouvelles commandes</span>
                <span className="block text-xs text-charcoal-400">Inclure les commandes non lues dans les alertes</span>
              </span>
              <input type="checkbox" checked={preferences.notifyOrders} onChange={(event) => updatePreference('notifyOrders', event.target.checked)} className="h-4 w-4 accent-brand-red" />
            </label>
            <label className="flex items-center justify-between gap-4 rounded-lg border border-charcoal-400/15 p-3">
              <span>
                <span className="block text-sm font-medium text-offwhite">Demandes sur mesure</span>
                <span className="block text-xs text-charcoal-400">Inclure les nouvelles demandes dans les alertes</span>
              </span>
              <input type="checkbox" checked={preferences.notifyCustomRequests} onChange={(event) => updatePreference('notifyCustomRequests', event.target.checked)} className="h-4 w-4 accent-brand-red" />
            </label>
            <div className="flex flex-col justify-between gap-3 rounded-lg border border-charcoal-400/15 p-3 sm:flex-row sm:items-center">
              <div>
                <p className="text-sm font-medium text-offwhite">Notifications du navigateur</p>
                <p className="mt-1 text-xs text-charcoal-400">Uniquement lorsque l’application est ouverte; pas d’envoi après fermeture complète du navigateur.</p>
              </div>
              <button type="button" onClick={() => void toggleBrowserNotifications()} className="btn-secondary flex-shrink-0 px-3 py-2 text-xs">
                {preferences.browserNotifications ? 'Désactiver' : 'Activer'}
              </button>
            </div>
            <div className="flex flex-col justify-between gap-3 rounded-lg border border-charcoal-400/15 p-3 sm:flex-row sm:items-center">
              <div>
                <p className="flex items-center gap-2 text-sm font-medium text-offwhite"><Volume2 className="h-4 w-4" /> Son des alertes</p>
                <p className="mt-1 text-xs text-charcoal-400">Un signal bref par nouvel événement reçu pendant que cette page est ouverte.</p>
              </div>
              <div className="flex gap-2">
                <button type="button" onClick={() => updatePreference('soundNotifications', !preferences.soundNotifications)} className="btn-secondary px-3 py-2 text-xs">
                  {preferences.soundNotifications ? 'Désactiver' : 'Activer'}
                </button>
                <button type="button" onClick={testSound} className="btn-ghost px-3 py-2 text-xs">Tester</button>
              </div>
            </div>
          </div>
          {preferenceMessage && <p role="status" className="mt-3 text-xs text-charcoal-200">{preferenceMessage}</p>}
        </section>




        <button type="button" onClick={save} disabled={saving} className="btn-primary w-full sm:w-auto">
          {saving ? <Loader2 className="h-4 w-4 animate-spin" /> : <Save className="h-4 w-4" />}
          Enregistrer les paramètres
        </button>
      </div>
    </div>
  )
}
