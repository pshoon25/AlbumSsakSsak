import SwiftUI
import WebKit

struct SVGWebView: UIViewRepresentable {
    // 내부 정적 SVG 상수
    private static let loadingSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 300 300">
      <path id="broom" d="M235.5,216.81c-22.56-11-35.5-34.58-35.5-64.8V134.73a15.94,15.94,0,0,0-10.09-14.87L165,110a8,8,0,0,1-4.48-10.34l21.32-53a28,28,0,0,0-16.1-37,28.14,28.14,0,0,0-35.82,16,.61.61,0,0,0,0,.12L108.9,79a8,8,0,0,1-10.37,4.49L73.11,73.14A15.89,15.89,0,0,0,55.74,76.8C34.68,98.45,24,123.75,24,152a111.45,111.45,0,0,0,31.18,77.53A8,8,0,0,0,61,232H232a8,8,0,0,0,3.5-15.19ZM67.14,88l25.41,10.3a24,24,0,0,0,31.23-13.45l21-53c2.56-6.11,9.47-9.27,15.43-7a12,12,0,0,1,6.88,15.92L145.69,93.76a24,24,0,0,0,13.43,31.14L184,134.73V152c0,.33,0,.66,0,1L55.77,101.71A108.84,108.84,0,0,1,67.14,88Zm48,128a87.53,87.53,0,0,1-24.34-42,8,8,0,0,0-15.49,4,105.16,105.16,0,0,0,18.36,38H64.44A95.54,95.54,0,0,1,40,152a85.9,85.9,0,0,1,7.73-36.29l137.8,55.12c3,18,10.56,33.48,21.89,45.16Z" fill="#333" />
      <g id="dust">
        <circle cx="40" cy="220" r="2" fill="#999" opacity="0.7">
          <animate attributeName="cx" values="40;60;50" dur="1.5s" repeatCount="indefinite" />
          <animate attributeName="cy" values="220;210;225" dur="1.5s" repeatCount="indefinite" />
          <animate attributeName="opacity" values="0.7;0.3;0.7" dur="1.5s" repeatCount="indefinite" />
        </circle>
        <circle cx="50" cy="230" r="1.5" fill="#999" opacity="0.6">
          <animate attributeName="cx" values="50;80;60" dur="1.8s" repeatCount="indefinite" />
          <animate attributeName="cy" values="230;225;235" dur="1.8s" repeatCount="indefinite" />
          <animate attributeName="opacity" values="0.6;0.2;0.6" dur="1.8s" repeatCount="indefinite" />
        </circle>
        <circle cx="60" cy="225" r="2.5" fill="#999" opacity="0.5">
          <animate attributeName="cx" values="60;90;70" dur="2s" repeatCount="indefinite" />
          <animate attributeName="cy" values="225;215;230" dur="2s" repeatCount="indefinite" />
          <animate attributeName="opacity" values="0.5;0.1;0.5" dur="2s" repeatCount="indefinite" />
        </circle>
        <circle cx="200" cy="220" r="2" fill="#999" opacity="0.7">
          <animate attributeName="cx" values="200;220;210" dur="1.7s" repeatCount="indefinite" />
          <animate attributeName="cy" values="220;210;225" dur="1.7s" repeatCount="indefinite" />
          <animate attributeName="opacity" values="0.7;0.3;0.7" dur="1.7s" repeatCount="indefinite" />
        </circle>
        <circle cx="210" cy="230" r="1.5" fill="#999" opacity="0.6">
          <animate attributeName="cx" values="210;240;220" dur="1.9s" repeatCount="indefinite" />
          <animate attributeName="cy" values="230;220;235" dur="1.9s" repeatCount="indefinite" />
          <animate attributeName="opacity" values="0.6;0.2;0.6" dur="1.9s" repeatCount="indefinite" />
        </circle>
      </g>
      <animateTransform 
        xlink:href="#broom"
        attributeName="transform"
        type="rotate"
        from="-15 150 150"
        to="15 150 150"
        dur="1s"
        repeatCount="indefinite"
        additive="sum"
        calcMode="spline"
        keySplines="0.5 0 0.5 1; 0.5 0 0.5 1"
        keyTimes="0; 0.5; 1"
        values="-15 150 150; 15 150 150; -15 150 150"
      />
      <animateTransform 
        xlink:href="#broom"
        attributeName="transform"
        type="translate"
        from="-20 0"
        to="20 0"
        dur="1s"
        repeatCount="indefinite"
        additive="sum"
        calcMode="spline"
        keySplines="0.5 0 0.5 1; 0.5 0 0.5 1"
        keyTimes="0; 0.5; 1"
        values="-20 0; 20 0; -20 0"
      />
      <animateTransform 
        xlink:href="#dust"
        attributeName="transform"
        type="translate"
        from="-20 0"
        to="20 0"
        dur="1s"
        repeatCount="indefinite"
        calcMode="spline"
        keySplines="0.5 0 0.5 1; 0.5 0 0.5 1"
        keyTimes="0; 0.5; 1"
        values="-20 0; 20 0; -20 0"
      />
    </svg>
    """
    
    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <style>
                body { 
                    margin: 0; 
                    display: flex; 
                    justify-content: center; 
                    align-items: center; 
                    background: transparent; 
                }
                svg { 
                    width: 100px; 
                    height: 100px; 
                }
            </style>
        </head>
        <body>
            \(Self.loadingSVG)
        </body>
        </html>
        """
        uiView.loadHTMLString(html, baseURL: nil)
    }
}
