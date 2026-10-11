import { useEffect, useMemo, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { createClient } from '@supabase/supabase-js';
import './styles.css';

const SUPABASE_URL = import.meta.env.VITE_SUPABASE_URL;
const SUPABASE_PUBLISHABLE_KEY = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY;
const supabase = SUPABASE_URL && SUPABASE_PUBLISHABLE_KEY
  ? createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY)
  : null;

const PAYMENT_LABELS = {
  cash: 'Efectivo',
  card: 'Tarjeta',
  qr: 'QR',
};

const DELIVERY_STATUS = {
  offered: ['Publicado', 'status-offered'],
  accepted: ['Aceptado', 'status-accepted'],
  pickedUp: ['En recorrido', 'status-picked'],
  delivered: ['Entregado', 'status-delivered'],
  notDelivered: ['No entregado', 'status-alert'],
  cancelled: ['Cancelado', 'status-cancelled'],
  expired: ['Vencido', 'status-cancelled'],
};

const emptyForm = {
  documentNumber: '',
  firstName: '',
  lastName: '',
  clientName: '',
  clientPhone: '',
  neighborhood: '',
  address: '',
  addressReference: '',
  addressLabel: 'Principal',
  customerAddressId: '',
  productSummary: '',
  notes: '',
  paymentMethod: 'cash',
  paymentAmount: '',
  cashExpected: '',
  serviceType: 'Domicilio normal',
  kind: 'pharmacyToHome',
  crossCount: '0',
  purchaseCount: '0',
  changeOfMoney: false,
  hasDataphone: false,
};

function formatMoney(value) {
  const amount = Number(value || 0);
  return new Intl.NumberFormat('es-CO', {
    style: 'currency',
    currency: 'COP',
    maximumFractionDigits: 0,
  }).format(amount);
}

function formatDate(value) {
  if (!value) return 'Sin fecha';
  return new Intl.DateTimeFormat('es-CO', {
    day: '2-digit',
    month: 'short',
    hour: '2-digit',
    minute: '2-digit',
  }).format(new Date(value));
}

function localDateIso(date = new Date()) {
  const localDate = new Date(date.getTime() - date.getTimezoneOffset() * 60000);
  return localDate.toISOString().slice(0, 10);
}

function normalizeDocumentNumber(value) {
  return value.trim().toLowerCase().replace(/[^a-z0-9]/g, '');
}

function formatTime(value) {
  return value ? String(value).slice(0, 5) : '—';
}

function makePublicCode() {
  const date = new Date().toISOString().slice(0, 10).replaceAll('-', '');
  const token = crypto.randomUUID().slice(0, 6).toUpperCase();
  return `FN-${date}-${token}`;
}

function getErrorMessage(error) {
  if (!error) return 'Ocurrió un error inesperado.';
  if (error.message?.includes('Invalid login credentials')) {
    return 'Correo o contraseña incorrectos.';
  }
  if (error.message?.includes('Failed to fetch')) {
    return 'No se pudo conectar con Supabase. Revisa la conexión.';
  }
  return error.message || 'Ocurrió un error inesperado.';
}

function normalizeAuthIdentifier(value) {
  const normalized = value.trim().toLowerCase();
  return normalized.includes('@') ? normalized : `${normalized}@farmanorte.local`;
}

function BrandLogo({ inverse = false }) {
  if (inverse) {
    return (
      <div className="brand-logo-inverse" role="img" aria-label="FarmaNorte">
        <svg viewBox="0 0 44 44" aria-hidden="true">
          <circle cx="22" cy="22" r="18.5" fill="none" stroke="currentColor" strokeWidth="2.8" />
          <path d="M15 30V14.5h15M15 21.5h11" fill="none" stroke="currentColor" strokeWidth="3.2" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
        <span>Farmanorte</span>
      </div>
    );
  }

  return <img className="brand-logo" src={`${import.meta.env.BASE_URL}farmanorte-logo.png`} alt="FarmaNorte" />;
}

const HERO_TITLE = 'Cada entrega, siempre registrada.';
const HERO_COPY = 'Publica, sigue y deja registrado cada domicilio desde el punto de farmacia.';

function LoginHeroCopy() {
  const [visibleTitle, setVisibleTitle] = useState('');
  const [visibleCopy, setVisibleCopy] = useState('');
  const [reducedMotion, setReducedMotion] = useState(false);

  useEffect(() => {
    const mediaQuery = window.matchMedia('(prefers-reduced-motion: reduce)');
    const syncMotionPreference = () => setReducedMotion(mediaQuery.matches);
    syncMotionPreference();
    mediaQuery.addEventListener?.('change', syncMotionPreference);
    return () => mediaQuery.removeEventListener?.('change', syncMotionPreference);
  }, []);

  useEffect(() => {
    if (reducedMotion) {
      setVisibleTitle(HERO_TITLE);
      setVisibleCopy(HERO_COPY);
      return undefined;
    }

    let titleIndex = 0;
    let copyIndex = 0;
    let phase = 'title';
    let timer;

    const tick = () => {
      if (document.hidden) {
        timer = window.setTimeout(tick, 900);
        return;
      }

      if (phase === 'title') {
        titleIndex = Math.min(titleIndex + 1, HERO_TITLE.length);
        setVisibleTitle(HERO_TITLE.slice(0, titleIndex));
        if (titleIndex === HERO_TITLE.length) {
          phase = 'copy';
          timer = window.setTimeout(tick, 260);
          return;
        }
        timer = window.setTimeout(tick, 105);
        return;
      }

      if (phase === 'copy') {
        copyIndex = Math.min(copyIndex + 1, HERO_COPY.length);
        setVisibleCopy(HERO_COPY.slice(0, copyIndex));
        if (copyIndex === HERO_COPY.length) {
          phase = 'hold';
          timer = window.setTimeout(tick, 2200);
          return;
        }
        timer = window.setTimeout(tick, 48);
        return;
      }

      if (phase === 'hold') {
        setVisibleCopy('');
        setVisibleTitle('');
        copyIndex = 0;
        titleIndex = 0;
        phase = 'title';
        timer = window.setTimeout(tick, 620);
        return;
      }
    };

    timer = window.setTimeout(tick, 520);
    return () => window.clearTimeout(timer);
  }, [reducedMotion]);

  return (
    <>
      <span className="section-kicker">Red de domicilios</span>
      <div className="hero-copy-animated" aria-hidden="true">
        <h1>{visibleTitle}<span className="hero-caret">|</span></h1>
        <p>{visibleCopy}</p>
      </div>
      <span className="sr-only">{HERO_TITLE} {HERO_COPY}</span>
    </>
  );
}

function LoginRouteMotion() {
  const routeRef = useRef(null);

  useEffect(() => {
    const route = routeRef.current;
    if (!route) return undefined;

    const measureRoute = () => {
      const distance = Math.max(0, route.clientWidth - 18);
      route.style.setProperty('--route-distance', `${distance}px`);
      route.style.setProperty('--route-half-distance', `${distance / 2}px`);
    };

    measureRoute();
    const observer = typeof ResizeObserver === 'undefined'
      ? null
      : new ResizeObserver(measureRoute);
    observer?.observe(route);
    return () => observer?.disconnect();
  }, []);

  return (
    <div className="hero-route" aria-hidden="true">
      <div className="hero-route-track">
        <span className="hero-route-node route-node-one" />
        <span className="hero-route-node route-node-two" />
        <span className="hero-route-node route-node-three" />
        <span className="hero-route-runner" ref={routeRef} />
      </div>
      <span className="hero-route-label">RUTA ACTIVA · EN VIVO</span>
    </div>
  );
}

function LoginFormAtmosphere({ orbitRef, glowRef }) {
  return (
    <div className="login-atmosphere" aria-hidden="true">
      <div className="login-atmosphere-glow" ref={glowRef} />
      <div className="login-atmosphere-orbit" ref={orbitRef}>
        <span className="atmosphere-ring ring-one" />
        <span className="atmosphere-ring ring-two" />
        <span className="atmosphere-ring ring-three" />
        <span className="atmosphere-core" />
      </div>
      <span className="atmosphere-star star-one" />
      <span className="atmosphere-star star-two" />
      <span className="atmosphere-star star-three" />
      <span className="atmosphere-star star-four" />
    </div>
  );
}

function App() {
  const [session, setSession] = useState(null);
  const [profile, setProfile] = useState(null);
  const [pharmacy, setPharmacy] = useState(null);
  const [zone, setZone] = useState(null);
  const [zoneCouriers, setZoneCouriers] = useState([]);
  const [deliveries, setDeliveries] = useState([]);
  const [loading, setLoading] = useState(Boolean(supabase));
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const [activeView, setActiveView] = useState('publish');
  const [form, setForm] = useState(emptyForm);
  const [customerAddresses, setCustomerAddresses] = useState([]);
  const [customerLoading, setCustomerLoading] = useState(false);
  const [publishing, setPublishing] = useState(false);

  useEffect(() => {
    if (!supabase) {
      setLoading(false);
      return undefined;
    }

    let mounted = true;
    let channel;
    let lastUserId = null;
    let loadRequest = 0;

    const clearWorkspace = () => {
      setProfile(null);
      setPharmacy(null);
      setZone(null);
      setZoneCouriers([]);
      setDeliveries([]);
    };

    const loadWorkspace = async (userId) => {
      const requestId = ++loadRequest;
      const isCurrent = () => mounted && requestId === loadRequest;
      setLoading(true);
      setError('');
      clearWorkspace();

      const { data: profileData, error: profileError } = await supabase
        .from('profiles')
        .select('id, full_name, role, pharmacy_code, phone, active')
        .eq('id', userId)
        .maybeSingle();

      if (!isCurrent()) return;
      if (profileError) {
        setError(getErrorMessage(profileError));
        setLoading(false);
        return;
      }
      if (!profileData) {
        setError('Tu usuario está autenticado, pero todavía no tiene perfil operativo.');
        setLoading(false);
        return;
      }
      setProfile(profileData);

      if (!profileData.active) {
        setError('Este usuario está inactivo. Contacta al administrador.');
        setLoading(false);
        return;
      }
      if (profileData.role !== 'pharmacy') {
        setError(`Esta página es para usuarios de farmacia. Tu rol actual es ${profileData.role}.`);
        setLoading(false);
        return;
      }
      if (!profileData.pharmacy_code) {
        setError('Tu usuario todavía no tiene una farmacia asignada.');
        setLoading(false);
        return;
      }

      const { data: pharmacyData, error: pharmacyError } = await supabase
        .from('pharmacies')
        .select('code, name, zone_name, address, active')
        .eq('code', profileData.pharmacy_code)
        .maybeSingle();

      if (!isCurrent()) return;
      if (pharmacyError) {
        setError(getErrorMessage(pharmacyError));
        setLoading(false);
        return;
      }
      if (!pharmacyData || !pharmacyData.active) {
        setError('La farmacia asignada no existe o está inactiva.');
        setLoading(false);
        return;
      }
      setPharmacy(pharmacyData);

      const { data: directZone, error: directZoneError } = await supabase
        .from('zones')
        .select('id, name, active')
        .eq('name', pharmacyData.zone_name)
        .eq('active', true)
        .maybeSingle();

      if (!isCurrent()) return;
      if (directZoneError) {
        setError(getErrorMessage(directZoneError));
        setLoading(false);
        return;
      }
      setZone(directZone ?? null);

      const loadZoneCouriers = async () => {
        if (!directZone?.id) {
          setZoneCouriers([]);
          return;
        }
        const { data: courierData, error: courierError } = await supabase.rpc(
          'get_pharmacy_zone_couriers',
          {
            requested_zone_id: directZone.id,
            requested_date: localDateIso(),
          },
        );
        if (!isCurrent()) return;
        if (courierError) {
          setZoneCouriers([]);
          setError(getErrorMessage(courierError));
          return;
        }
        setZoneCouriers(courierData ?? []);
      };

      await loadZoneCouriers();
      if (!isCurrent()) return;

      const { data: deliveryData, error: deliveriesError } = await supabase
        .from('deliveries')
        .select('*')
        .eq('pharmacy_code', pharmacyData.code)
        .order('created_at', { ascending: false })
        .limit(30);

      if (!isCurrent()) return;
      if (deliveriesError) {
        setError(getErrorMessage(deliveriesError));
      } else {
        setDeliveries(deliveryData ?? []);
      }
      setLoading(false);

      if (channel) {
        await supabase.removeChannel(channel);
        channel = null;
      }
      channel = supabase
        .channel(`pharmacy-deliveries-${pharmacyData.code}-${requestId}`)
        .on(
          'postgres_changes',
          {
            event: '*',
            schema: 'public',
            table: 'deliveries',
            filter: `pharmacy_code=eq.${pharmacyData.code}`,
          },
          (payload) => {
            setDeliveries((current) => {
              if (payload.eventType === 'DELETE') {
                return current.filter((item) => item.id !== payload.old.id);
              }
              const next = current.filter((item) => item.id !== payload.new.id);
              return [payload.new, ...next].sort(
                (left, right) => new Date(right.created_at) - new Date(left.created_at),
              ).slice(0, 30);
            });
          },
        )
        .on(
          'postgres_changes',
          { event: '*', schema: 'public', table: 'shifts' },
          () => void loadZoneCouriers(),
        )
        .on(
          'postgres_changes',
          { event: '*', schema: 'public', table: 'courier_presence' },
          () => void loadZoneCouriers(),
        )
        .subscribe();
    };

    const applySession = (nextSession) => {
      if (!mounted) return;
      setSession(nextSession);
      if (!nextSession) {
        lastUserId = null;
        loadRequest += 1;
        clearWorkspace();
        setLoading(false);
        return;
      }
      if (lastUserId === nextSession.user.id) return;
      lastUserId = nextSession.user.id;
      void loadWorkspace(nextSession.user.id);
    };

    const loadSession = async () => {
      setLoading(true);
      setError('');
      const { data, error: sessionError } = await supabase.auth.getSession();
      if (!mounted) return;
      if (sessionError) {
        setError(getErrorMessage(sessionError));
        setLoading(false);
        return;
      }
      applySession(data.session ?? null);
    };

    const { data: authListener } = supabase.auth.onAuthStateChange((_event, nextSession) => {
      applySession(nextSession);
    });

    void loadSession();

    return () => {
      mounted = false;
      loadRequest += 1;
      authListener.subscription.unsubscribe();
      if (channel) supabase.removeChannel(channel);
    };
  }, []);

  const signOut = async () => {
    if (!supabase) return;
    await supabase.auth.signOut();
  };

  const loadCustomer = async () => {
    const documentNumber = form.documentNumber.trim();
    const normalizedDocumentNumber = normalizeDocumentNumber(documentNumber);
    if (!normalizedDocumentNumber || !pharmacy) {
      setError('Escribe el número de documento para buscar el cliente.');
      return;
    }

    setCustomerLoading(true);
    setError('');
    setNotice('');
    const { data: customerData, error: customerError } = await supabase
      .from('customers')
      .select('id, document_number, first_name, last_name, phone')
      .eq('document_number_normalized', normalizedDocumentNumber)
      .maybeSingle();

    if (customerError) {
      setError(getErrorMessage(customerError));
      setCustomerLoading(false);
      return;
    }

    if (!customerData) {
      setCustomerAddresses([]);
      setForm((current) => ({
        ...current,
        customerAddressId: '',
        firstName: '',
        lastName: '',
        clientName: '',
        clientPhone: '',
        neighborhood: '',
        address: '',
        addressReference: '',
        addressLabel: 'Principal',
      }));
      setNotice('Cliente nuevo. Completa sus datos y quedará guardado al publicar.');
      setCustomerLoading(false);
      return;
    }

    const { data: addressData, error: addressError } = await supabase
      .from('customer_addresses')
      .select('id, label, neighborhood, address, address_reference, is_default')
      .eq('customer_id', customerData.id)
      .eq('active', true)
      .order('is_default', { ascending: false })
      .order('created_at', { ascending: true });

    if (addressError) {
      setError(getErrorMessage(addressError));
      setCustomerLoading(false);
      return;
    }

    const addresses = addressData ?? [];
    const selectedAddress = addresses[0];
    const fullName = `${customerData.first_name ?? ''} ${customerData.last_name ?? ''}`.trim();
    setCustomerAddresses(addresses);
    setForm((current) => ({
      ...current,
      firstName: customerData.first_name ?? '',
      lastName: customerData.last_name ?? '',
      clientName: fullName,
      clientPhone: customerData.phone ?? '',
      customerAddressId: selectedAddress?.id ?? '',
      addressLabel: selectedAddress?.label ?? 'Principal',
      neighborhood: selectedAddress?.neighborhood ?? '',
      address: selectedAddress?.address ?? '',
      addressReference: selectedAddress?.address_reference ?? '',
    }));
    setNotice(`Cliente encontrado: ${fullName || documentNumber}.`);
    setCustomerLoading(false);
  };

  const selectCustomerAddress = (addressId) => {
    const address = customerAddresses.find((item) => item.id === addressId);
    if (!address) return;
    setForm((current) => ({
      ...current,
      customerAddressId: address.id,
      addressLabel: address.label,
      neighborhood: address.neighborhood,
      address: address.address,
      addressReference: address.address_reference ?? '',
    }));
    setNotice(`Dirección seleccionada: ${address.label}.`);
  };

  const startNewAddress = () => {
    setForm((current) => ({
      ...current,
      customerAddressId: '',
      addressLabel: `Dirección ${customerAddresses.length + 1}`,
      neighborhood: '',
      address: '',
      addressReference: '',
    }));
    setNotice('Nueva dirección lista para guardar con el próximo domicilio.');
  };

  const publishDelivery = async (event) => {
    event.preventDefault();
    if (!supabase || !session || !profile || !pharmacy) return;
    if (!zone) {
      setError(`La farmacia no tiene una zona activa configurada (${pharmacy.zone_name}). El administrador debe configurarla antes de publicar.`);
      return;
    }

    const requiredFields = [
      ['documentNumber', 'número de documento'],
      ['firstName', 'nombre del cliente'],
      ['lastName', 'apellido del cliente'],
      ['clientPhone', 'teléfono del cliente'],
      ['neighborhood', 'barrio'],
      ['address', 'dirección'],
      ['addressReference', 'referencia de ubicación'],
      ['productSummary', 'descripción del pedido'],
    ];
    const missing = requiredFields.find(([key]) => !String(form[key]).trim());
    if (missing) {
      setError(`Completa el campo: ${missing[1]}.`);
      return;
    }
    if (form.paymentMethod === 'cash' && !Number(form.cashExpected)) {
      setError('Indica con cuánto pagará el cliente en efectivo.');
      return;
    }

    setPublishing(true);
    setError('');
    setNotice('');
    const fullName = `${form.firstName.trim()} ${form.lastName.trim()}`.trim();
    const { data: customerData, error: customerError } = await supabase
      .from('customers')
      .upsert(
        {
          document_number: form.documentNumber.trim(),
          first_name: form.firstName.trim(),
          last_name: form.lastName.trim(),
          phone: form.clientPhone.trim(),
          active: true,
          created_by: session.user.id,
        },
        { onConflict: 'document_number_normalized' },
      )
      .select('id')
      .single();

    if (customerError || !customerData) {
      setError(getErrorMessage(customerError));
      setPublishing(false);
      return;
    }

    let customerAddressId = form.customerAddressId || null;
    if (!customerAddressId) {
      const { data: addressData, error: addressError } = await supabase
        .from('customer_addresses')
        .insert({
          customer_id: customerData.id,
          label: form.addressLabel.trim() || 'Principal',
          neighborhood: form.neighborhood.trim(),
          address: form.address.trim(),
          address_reference: form.addressReference.trim(),
          is_default: customerAddresses.length === 0,
        })
        .select('id')
        .single();
      if (addressError || !addressData) {
        setError(getErrorMessage(addressError));
        setPublishing(false);
        return;
      }
      customerAddressId = addressData.id;
    }

    const payload = {
      public_code: makePublicCode(),
      pharmacy_code: pharmacy.code,
      zone_id: zone.id,
      kind: form.kind,
      service_type: form.serviceType,
      status: 'offered',
      client_name: fullName,
      client_phone: form.clientPhone.trim(),
      customer_id: customerData.id,
      customer_address_id: customerAddressId,
      neighborhood: form.neighborhood.trim(),
      address: form.address.trim(),
      address_reference: form.addressReference.trim(),
      notes: form.notes.trim() || null,
      product_summary: form.productSummary.trim(),
      payment_method: form.paymentMethod,
      payment_amount: Number(form.paymentAmount) || 0,
      cash_expected: form.paymentMethod === 'cash' ? Number(form.cashExpected) : null,
      total_to_collect: Number(form.paymentAmount) || 0,
      cross_count: Number(form.crossCount) || 0,
      purchase_count: Number(form.purchaseCount) || 0,
      change_of_money: form.changeOfMoney,
      has_dataphone: form.paymentMethod === 'card' || form.hasDataphone,
      pickup_stops: [{ pharmacy_code: pharmacy.code, label: pharmacy.name }],
      destination_options: [],
      approval_pending: false,
      created_by: session.user.id,
      expires_at: new Date(Date.now() + 3 * 60 * 1000).toISOString(),
    };

    const { data, error: insertError } = await supabase
      .from('deliveries')
      .insert(payload)
      .select('*')
      .single();

    if (insertError) {
      setError(getErrorMessage(insertError));
      setPublishing(false);
      return;
    }

    setForm(emptyForm);
    setCustomerAddresses([]);
    setActiveView('history');
    setPublishing(false);
    setNotice(`Domicilio ${data.public_code} publicado. La oferta vence en 3 minutos.`);
  };

  if (!supabase) return <ConfigScreen />;
  if (!session) return <LoginScreen />;
  if (error && (!profile || profile.role !== 'pharmacy' || !pharmacy)) {
    return <AccessProblem error={error} onSignOut={signOut} />;
  }
  if (loading || !profile || !pharmacy) return <LoadingScreen />;

  const assignedCouriers = [...new Map(
    zoneCouriers.map((courier) => [courier.courier_id, courier]),
  ).values()];
  const firstName = (profile.full_name || 'equipo').trim().split(/\s+/)[0];

  return (
    <div className="app-shell">
      <aside className="sidebar">
        <div className="brand-lockup">
          <BrandLogo />
        </div>

        <div className="sidebar-section-label">Módulo farmacia</div>
        <nav className="main-nav" aria-label="Navegación principal">
          <button className={activeView === 'publish' ? 'nav-item active' : 'nav-item'} onClick={() => setActiveView('publish')}>
            <span className="nav-icon">＋</span>
            <span>Publicar domicilio</span>
          </button>
          <button className={activeView === 'history' ? 'nav-item active' : 'nav-item'} onClick={() => setActiveView('history')}>
            <span className="nav-icon">◷</span>
            <span>Historial</span>
            <span className="nav-count">{deliveries.length}</span>
          </button>
        </nav>

        <div className="sidebar-bottom">
          <div className="connection-card">
            <span className="pulse-dot" />
            <div>
              <strong>Supabase conectado</strong>
              <span>Datos reales en tiempo real</span>
            </div>
          </div>
          <button className="sign-out-link" onClick={signOut}>Cerrar sesión <span>↗</span></button>
        </div>
      </aside>

      <main className="main-content">
        <header className="topbar">
          <div>
            <p className="welcome-line">Bienvenido, {firstName}</p>
            <p className="eyebrow">Panel de farmacia <span className="live-pill">EN VIVO</span></p>
            <h1>{activeView === 'publish' ? 'Nuevo domicilio' : 'Historial de domicilios'}</h1>
          </div>
          <div className="operator-info">
            <div className="operator-avatar">{(profile.full_name || 'F').slice(0, 1).toUpperCase()}</div>
            <div>
              <strong>{profile.full_name}</strong>
              <span>{pharmacy.name} · FN {pharmacy.code}</span>
            </div>
          </div>
        </header>

        {error && <div className="inline-alert error-alert" role="alert">{error}<button aria-label="Cerrar error" onClick={() => setError('')}>×</button></div>}
        {notice && <div className="inline-alert success-alert" role="status">{notice}<button aria-label="Cerrar aviso" onClick={() => setNotice('')}>×</button></div>}

        {activeView === 'publish' ? (
          <div className="workspace-grid">
            <section className="form-card">
              <div className="card-heading">
                <div>
                  <span className="section-kicker">Salida inmediata</span>
                  <h2>Datos del domicilio</h2>
                </div>
                <div className="zone-chip"><span /> Zona {pharmacy.zone_name}</div>
              </div>

              <form onSubmit={publishDelivery}>
                <div className="form-section">
                  <div className="form-section-title"><span>01</span><div><strong>Cliente y ubicación</strong><small>La dirección puede usar manzana, calle o carrera.</small></div></div>
                  <div className="field-grid two-columns">
                    <Field label="Documento" required><div className="inline-field"><input value={form.documentNumber} onChange={(event) => setForm({ ...form, documentNumber: event.target.value })} placeholder="Número de documento" inputMode="numeric" /><button type="button" className="secondary-button compact-button" onClick={loadCustomer} disabled={customerLoading}>{customerLoading ? 'Buscando…' : 'Buscar'}</button></div></Field>
                    <Field label="Teléfono" required><input value={form.clientPhone} onChange={(event) => setForm({ ...form, clientPhone: event.target.value })} placeholder="300 000 0000" inputMode="tel" /></Field>
                    <Field label="Nombre" required><input value={form.firstName} onChange={(event) => setForm({ ...form, firstName: event.target.value })} placeholder="Nombre" /></Field>
                    <Field label="Apellido" required><input value={form.lastName} onChange={(event) => setForm({ ...form, lastName: event.target.value })} placeholder="Apellido" /></Field>
                    <Field label="Barrio" required><input value={form.neighborhood} onChange={(event) => setForm({ ...form, customerAddressId: '', neighborhood: event.target.value })} placeholder="Ej. Cantaclaro" /></Field>
                    <Field label="Dirección" required><input value={form.address} onChange={(event) => setForm({ ...form, customerAddressId: '', address: event.target.value })} placeholder="Mz 4 casa 12 / Cra 8 # 24-10" /></Field>
                  </div>
                  {customerAddresses.length > 0 && <div className="address-picker"><label className="field"><span>Direcciones guardadas</span><select value={form.customerAddressId} onChange={(event) => selectCustomerAddress(event.target.value)}><option value="">Nueva dirección</option>{customerAddresses.map((address) => <option key={address.id} value={address.id}>{address.label} · {address.neighborhood}</option>)}</select></label><button type="button" className="text-button" onClick={startNewAddress}>＋ Agregar otra dirección</button></div>}
                  <div className="field-grid two-columns">
                    <Field label="Etiqueta de dirección"><input value={form.addressLabel} onChange={(event) => setForm({ ...form, customerAddressId: '', addressLabel: event.target.value })} placeholder="Casa, trabajo…" /></Field>
                    <Field label="Referencia de llegada" required><input value={form.addressReference} onChange={(event) => setForm({ ...form, customerAddressId: '', addressReference: event.target.value })} placeholder="Ej. Doblando el D1, casa de rejas blancas" /></Field>
                  </div>
                </div>

                <div className="form-section">
                  <div className="form-section-title"><span>02</span><div><strong>Pedido y servicio</strong><small>Estos datos viajan al domiciliario en la oferta.</small></div></div>
                  <Field label="Descripción del pedido" required><textarea value={form.productSummary} onChange={(event) => setForm({ ...form, productSummary: event.target.value })} placeholder="Productos, cantidades o instrucciones de recogida" rows="3" /></Field>
                  <div className="field-grid two-columns">
                    <Field label="Tipo de servicio"><select value={form.serviceType} onChange={(event) => setForm({ ...form, serviceType: event.target.value, kind: event.target.value === 'Cruce farmacia' ? 'pharmacyCross' : event.target.value === 'Compra externa' ? 'externalPurchase' : event.target.value === 'Cambio de menudo' ? 'changeOfMoney' : 'pharmacyToHome' })}><option>Domicilio normal</option><option>Compra externa</option><option>Cruce farmacia</option><option>Cambio de menudo</option></select></Field>
                    <Field label="Observación"><input value={form.notes} onChange={(event) => setForm({ ...form, notes: event.target.value })} placeholder="Instrucción opcional" /></Field>
                  </div>
                  <div className="compact-options">
                    <label className="checkbox-row"><input type="checkbox" checked={form.changeOfMoney} onChange={(event) => setForm({ ...form, changeOfMoney: event.target.checked })} /><span>Requiere cambio de menudo</span></label>
                    <label className="checkbox-row"><input type="checkbox" checked={form.hasDataphone} onChange={(event) => setForm({ ...form, hasDataphone: event.target.checked })} /><span>El domiciliario lleva datáfono</span></label>
                  </div>
                </div>

                <div className="form-section last-section">
                  <div className="form-section-title"><span>03</span><div><strong>Forma de pago</strong><small>Transferencia queda agrupada como QR.</small></div></div>
                  <div className="payment-switcher" role="radiogroup" aria-label="Forma de pago">
                    {Object.entries(PAYMENT_LABELS).map(([value, label]) => <button type="button" key={value} aria-pressed={form.paymentMethod === value} className={form.paymentMethod === value ? 'payment-choice active' : 'payment-choice'} onClick={() => setForm({ ...form, paymentMethod: value })}><span className={`payment-symbol ${value}`} aria-hidden="true">{value === 'cash' ? '$' : value === 'card' ? '▣' : '⌁'}</span>{label}</button>)}
                  </div>
                  <div className="field-grid two-columns payment-fields">
                    <Field label="Valor del pedido"><input value={form.paymentAmount} onChange={(event) => setForm({ ...form, paymentAmount: event.target.value })} placeholder="$ 0" inputMode="decimal" /></Field>
                    {form.paymentMethod === 'cash' ? <Field label="Cliente paga con" required><input value={form.cashExpected} onChange={(event) => setForm({ ...form, cashExpected: event.target.value })} placeholder="$ 0" inputMode="decimal" /></Field> : <div className="payment-hint"><span>✓</span> {form.paymentMethod === 'card' ? 'El domiciliario debe llevar datáfono.' : 'El domiciliario debe llevar lector QR.'}</div>}
                  </div>
                </div>

                <div className="form-actions"><span>La oferta quedará disponible durante 3 minutos.</span><button className="primary-button" disabled={publishing || !zone}>{publishing ? 'Publicando…' : 'Publicar domicilio'} <span>→</span></button></div>
              </form>
            </section>

            <aside className="side-column">
              <div className="info-card accent-card"><span className="card-icon">⌁</span><div><span className="section-kicker">Estado operativo</span><h3>{zone ? `Zona ${zone.name}` : 'Zona pendiente'}</h3><p>{zone ? 'Las ofertas serán visibles para domiciliarios conectados con esta zona asignada.' : 'Configura la zona en el panel administrador para habilitar publicaciones.'}</p></div></div>
              <div className="info-card zone-couriers-card">
                <div className="info-card-header">
                  <span className="section-kicker">Cobertura de hoy</span>
                  <span className="live-pill">{assignedCouriers.length} asignados</span>
                </div>
                <h3>{zone ? `Domiciliarios de ${zone.name}` : 'Domiciliarios de la zona'}</h3>
                {assignedCouriers.length > 0 ? (
                  <div className="zone-courier-list">
                    {assignedCouriers.map((courier) => (
                      <div className="zone-courier-row" key={courier.courier_id}>
                        <span className={courier.connected ? 'courier-avatar online' : 'courier-avatar'} aria-hidden="true">{(courier.full_name || 'D').slice(0, 1).toUpperCase()}</span>
                        <div className="zone-courier-main">
                          <strong>{courier.full_name || 'Domiciliario'}</strong>
                          <span>{formatTime(courier.starts_at)}–{formatTime(courier.ends_at)} · {courier.connected ? 'Conectado' : 'Programado'}</span>
                        </div>
                        {courier.phone ? <a className="zone-courier-phone" href={`tel:${courier.phone}`} aria-label={`Llamar a ${courier.full_name || 'domiciliario'}`}>{courier.phone}</a> : <span className="zone-courier-phone missing">Sin teléfono</span>}
                      </div>
                    ))}
                  </div>
                ) : <p className="empty-zone-couriers">No hay un domiciliario programado para esta zona hoy.</p>}
              </div>
              <div className="info-card"><div className="info-card-header"><span className="section-kicker">Actividad reciente</span><button onClick={() => setActiveView('history')}>Ver todo →</button></div>{deliveries.slice(0, 3).map((delivery) => <DeliveryRow key={delivery.id} delivery={delivery} />)}{deliveries.length === 0 && <EmptyActivity />}</div>
              <div className="process-card"><span className="section-kicker">Flujo registrado</span><div className="process-step"><span>1</span><div><strong>Publicas</strong><small>Oferta abierta por 3 min</small></div></div><div className="process-line" /><div className="process-step"><span>2</span><div><strong>Se acepta</strong><small>El domiciliario recibe el aviso</small></div></div><div className="process-line" /><div className="process-step"><span>3</span><div><strong>Se entrega</strong><small>El estado queda en historial</small></div></div></div>
            </aside>
          </div>
        ) : (
          <HistoryView deliveries={deliveries} pharmacy={pharmacy} />
        )}
      </main>
    </div>
  );
}

function Field({ label, required, children }) {
  return <label className="field"><span>{label}{required && <em> *</em>}</span>{children}</label>;
}

function DeliveryRow({ delivery }) {
  const [statusLabel, statusClass] = DELIVERY_STATUS[delivery.status] || ['Sin estado', 'status-cancelled'];
  return <div className="delivery-row"><div className="delivery-row-main"><strong>{delivery.public_code || delivery.id?.slice(0, 8)}</strong><span>{delivery.client_name} · {delivery.neighborhood}</span></div><div className="delivery-row-side"><span className={`status-badge ${statusClass}`}>{statusLabel}</span><small>{formatDate(delivery.created_at)}</small></div></div>;
}

function EmptyActivity() {
  return <div className="empty-activity"><span>⌁</span><p>Aún no hay domicilios publicados.</p><small>Los nuevos aparecerán aquí en tiempo real.</small></div>;
}

function HistoryView({ deliveries, pharmacy }) {
  const [filter, setFilter] = useState('all');
  const filtered = useMemo(() => filter === 'all' ? deliveries : deliveries.filter((delivery) => delivery.status === filter), [deliveries, filter]);
  return <section className="history-page"><div className="history-toolbar"><div><span className="section-kicker">Registro de {pharmacy.name}</span><h2>Todos los domicilios</h2><p>Historial recibido directamente desde Supabase. No hay registros locales.</p></div><div className="filter-row">{[['all', 'Todos'], ['offered', 'Publicados'], ['accepted', 'Aceptados'], ['delivered', 'Entregados']].map(([value, label]) => <button key={value} className={filter === value ? 'filter-button active' : 'filter-button'} onClick={() => setFilter(value)}>{label}</button>)}</div></div><div className="history-list">{filtered.map((delivery) => <DeliveryRow key={delivery.id} delivery={delivery} />)}{filtered.length === 0 && <div className="empty-history"><span>○</span><h3>No hay registros para mostrar</h3><p>Cuando publiques un domicilio aparecerá aquí.</p></div>}</div></section>;
}

function LoginScreen() {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState('');
  const atmosphereOrbitRef = useRef(null);
  const atmosphereGlowRef = useRef(null);
  const atmosphereFrameRef = useRef(null);
  const atmospherePointerRef = useRef({ x: 0, y: 0 });

  const moveAtmosphere = (event) => {
    const card = event.currentTarget;
    const bounds = card.getBoundingClientRect();
    atmospherePointerRef.current = {
      x: ((event.clientX - bounds.left) / bounds.width - 0.5) * 2,
      y: ((event.clientY - bounds.top) / bounds.height - 0.5) * 2,
    };
    if (atmosphereFrameRef.current !== null) return;
    atmosphereFrameRef.current = window.requestAnimationFrame(() => {
      atmosphereFrameRef.current = null;
      const { x, y } = atmospherePointerRef.current;
      if (atmosphereOrbitRef.current) {
        atmosphereOrbitRef.current.style.transform = `translate3d(${x * 14}px, ${y * 10}px, 0)`;
      }
      if (atmosphereGlowRef.current) {
        atmosphereGlowRef.current.style.transform = `translate3d(${x * -10}px, ${y * -8}px, 0)`;
      }
    });
  };

  const resetAtmosphere = () => {
    if (atmosphereFrameRef.current !== null) {
      window.cancelAnimationFrame(atmosphereFrameRef.current);
      atmosphereFrameRef.current = null;
    }
    if (atmosphereOrbitRef.current) atmosphereOrbitRef.current.style.transform = 'translate3d(0, 0, 0)';
    if (atmosphereGlowRef.current) atmosphereGlowRef.current.style.transform = 'translate3d(0, 0, 0)';
  };

  useEffect(() => () => resetAtmosphere(), []);

  const submit = async (event) => {
    event.preventDefault();
    setSubmitting(true);
    setError('');
    const { error: signInError } = await supabase.auth.signInWithPassword({ email: normalizeAuthIdentifier(email), password });
    if (signInError) setError(getErrorMessage(signInError));
    setSubmitting(false);
  };

  return <div className="auth-page"><div className="auth-aside"><div className="brand-lockup"><BrandLogo inverse /></div><div className="auth-quote"><LoginHeroCopy /><LoginRouteMotion /></div><div className="auth-aside-footer">Panel privado para personal autorizado</div></div><main className="auth-main"><div className="auth-form-wrap" onPointerMove={moveAtmosphere} onPointerLeave={resetAtmosphere}><LoginFormAtmosphere orbitRef={atmosphereOrbitRef} glowRef={atmosphereGlowRef} /><span className="section-kicker">Acceso de farmacia</span><h2>Inicia sesión</h2><p className="auth-copy">Usa el usuario que el administrador creó para tu farmacia.</p>{error && <div className="inline-alert error-alert" role="alert">{error}</div>}<form onSubmit={submit} className="auth-form"><Field label="Usuario o correo" required><input type="text" value={email} onChange={(event) => setEmail(event.target.value)} placeholder="juan.perez" autoComplete="username" required /></Field><Field label="Contraseña" required><input type="password" value={password} onChange={(event) => setPassword(event.target.value)} placeholder="••••••••" autoComplete="current-password" required /></Field><button className="primary-button full-width" disabled={submitting}>{submitting ? 'Validando…' : 'Entrar al panel'} <span>→</span></button></form><div className="auth-note"><span>●</span> Autenticación protegida por Supabase Auth</div></div></main></div>;
}

function ConfigScreen() {
  return <div className="center-screen"><div className="config-card"><BrandLogo /><span className="section-kicker">Configuración requerida</span><h1>Conecta el panel con Supabase</h1><p>Faltan <code>VITE_SUPABASE_URL</code> y <code>VITE_SUPABASE_PUBLISHABLE_KEY</code>. Cópialas en <code>pharmacy_web/.env.local</code> antes de ejecutar la página.</p><div className="config-code">VITE_SUPABASE_URL=https://tu-proyecto.supabase.co<br />VITE_SUPABASE_PUBLISHABLE_KEY=sb_publishable_...</div></div></div>;
}

function LoadingScreen() {
  return <div className="center-screen"><div className="loading-card"><div className="spinner" /><p>Validando usuario y cargando la farmacia…</p></div></div>;
}

function AccessProblem({ error, onSignOut }) {
  return <div className="center-screen"><div className="problem-card"><div className="problem-icon">!</div><span className="section-kicker">Acceso detenido</span><h1>No se cargó el panel</h1><p>{error}</p><button className="secondary-button" onClick={onSignOut}>Cerrar sesión</button></div></div>;
}

export default App;

createRoot(document.getElementById('root')).render(<App />);
