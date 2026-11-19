import { useState } from 'react'
import { useNavigate, Navigate } from 'react-router-dom'
import { Printer, Lock, Mail, Loader2, AlertCircle } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/lib/auth'
import { isPostHogEnabled, posthogLogger } from '@/lib/posthog'

export default function AdminLogin() {
  const { isOwner, loading } = useAuth()
  const navigate = useNavigate()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [submitting, setSubmitting] = useState(false)

  if (loading) {
    return (
      <div className="flex min-h-screen items-center justify-center bg-charcoal-950">
        <Loader2 className="h-8 w-8 animate-spin text-brand-red" />
      </div>
    )
  }

  if (isOwner) {
    return <Navigate to="/admin/dashboard" replace />
  }

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    if (submitting) return

    setError(null)
    setSubmitting(true)

    try {
      const { error: signInError } = await supabase.auth.signInWithPassword({
        email: email.trim(),
        password,
      })

      if (signInError) {
        if (isPostHogEnabled) {
          posthogLogger.warn('owner login rejected', { reason: 'invalid_credentials' })
        }
        setError('Identifiants invalides.')
        return
      }

      const { data: userData, error: userError } = await supabase.auth.getUser()
      if (userError || !userData.user) {
        await supabase.auth.signOut().catch(() => undefined)
        setError('Identifiants invalides.')
        return
      }

      const { data: profile, error: profileError } = await supabase
        .from('profiles')
        .select('role')
        .eq('id', userData.user.id)
        .maybeSingle()

      if (profileError || profile?.role !== 'owner') {
        if (isPostHogEnabled) {
          posthogLogger.warn('owner login rejected', { reason: 'not_authorized' })
        }
        await supabase.auth.signOut().catch(() => undefined)
        setError('Identifiants invalides.')
        return
      }

      // L'audit est utile mais ne doit pas empêcher un propriétaire authentifié
      // d'ouvrir le back office si le service de journalisation est indisponible.
      try {
        await supabase.rpc('log_owner_event', { p_action: 'proprietaire.connexion' })
      } catch {
        console.warn('[LUNDER] journalisation de connexion indisponible')
      }

      navigate('/admin/dashboard')
    } catch {
      setError('Connexion impossible pour le moment. Vérifiez votre connexion puis réessayez.')
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-charcoal-950 px-4">
      <div className="w-full max-w-md animate-scale-in">
        <div className="mb-8 text-center">
          <div className="mx-auto mb-4 flex h-14 w-14 items-center justify-center rounded-xl bg-brand-red">
            <Printer className="h-7 w-7 text-white" />
          </div>
          <h1 className="text-2xl font-bold text-offwhite">Espace propriétaire</h1>
          <p className="mt-2 text-sm text-charcoal-400">LUNDER'S 3D STUDIO</p>
        </div>

        <div className="card p-8">
          {error && (
            <div role="alert" aria-live="polite" className="mb-6 flex items-center gap-2 rounded-lg border border-brand-red/30 bg-brand-red/10 px-4 py-3 text-sm text-brand-red-light">
              <AlertCircle className="h-4 w-4 flex-shrink-0" />
              {error}
            </div>
          )}

          <form onSubmit={handleSubmit} className="flex flex-col gap-5">
            <div>
              <label htmlFor="email" className="label-text">Email</label>
              <div className="relative">
                <Mail className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-charcoal-400" />
                <input
                  id="email"
                  type="email"
                  autoComplete="username"
                  required
                  value={email}
                  onChange={(e) => setEmail(e.target.value)}
                  className="input-field pl-10"
                  placeholder="proprietaire@lunders.dz"
                />
              </div>
            </div>

            <div>
              <label htmlFor="password" className="label-text">Mot de passe</label>
              <div className="relative">
                <Lock className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-charcoal-400" />
                <input
                  id="password"
                  type="password"
                  autoComplete="current-password"
                  required
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  className="input-field pl-10"
                  placeholder="••••••••"
                />
              </div>
            </div>

            <button type="submit" disabled={submitting} className="btn-primary w-full">
              {submitting ? <Loader2 className="h-4 w-4 animate-spin" /> : 'Se connecter'}
            </button>
          </form>
        </div>

        <p className="mt-6 text-center text-xs text-charcoal-500">
          Accès réservé au propriétaire de la boutique.
        </p>
      </div>
    </div>
  )
}
