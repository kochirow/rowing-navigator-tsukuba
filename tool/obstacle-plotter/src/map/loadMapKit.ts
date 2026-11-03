const scriptUrl = 'https://cdn.apple-mapkit.com/mk/5.x.x/mapkit.js';

// Share the in-flight SDK load between StrictMode mounts; allow recovery.
let mapKitLoading: Promise<any> | undefined;
export async function loadMapKit(): Promise<any> {
  if ((window as any).mapkit) return (window as any).mapkit;
  if (mapKitLoading) return mapKitLoading;
  mapKitLoading = new Promise<any>((resolve, reject) => {
    const script = document.createElement('script');
    const fail = () => {
      window.clearTimeout(timeout);
      script.remove();
      reject(new Error('Apple Mapsの地図プログラムを読み込めませんでした。通信を確認して「地図を再試行」を押してください。'));
    };
    const timeout = window.setTimeout(fail, 20_000);
    script.src = scriptUrl;
    script.async = true;
    script.onload = () => {
      window.clearTimeout(timeout);
      if (!(window as any).mapkit) { fail(); return; }
      resolve((window as any).mapkit);
    };
    script.onerror = fail;
    document.head.append(script);
  }).catch((error) => { mapKitLoading = undefined; throw error; });
  return mapKitLoading;
}
